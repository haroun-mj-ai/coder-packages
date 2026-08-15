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
  has been recorded on the ticket's local queue entry (`state: needs-input`,
  `question` set). What happens to the *process* next is the wrapper's call
  — see "## Parking" — not something a skill's own instructions decide or
  need to know.
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
  (`$AP_HOME/parked/<eng-id>.json`: window name, lane, run dir, plan
  path, ports, the question) and releases the act's lane slot and per-issue
  lock immediately, so the pipeline's limited build/ship slots (2 and 3 by
  default) aren't tied up for however long the owner takes to reply — the
  exact property `oneshot` mode's "NEEDS_HUMAN frees the slot" already had,
  preserved here by a different mechanism.
- **Resuming**: a reply lands one of two ways, both converging on the same
  `ap-resume.sh <eng-id> [<reply-text>] [<feedback-seq>]` — re-acquires a
  slot from the normal pool, re-acquires the per-issue lock, then either
  injects the reply via `tmux send-keys` or (no reply text) just observes
  whatever the act has already moved to:
  1. **`ap reply <ENG-ID> "text"`**, exactly as today — this writes the
     ticket's `feedback` field and bumps `feedback_seq`; `ap-cycle.sh`'s
     `scan_parked_replies` notices the ticket's `feedback_seq` has advanced
     past what was last relayed and backgrounds `ap-resume.sh` with the
     reply text and the new `feedback_seq`.
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
- **The local queue write on `NEEDS_HUMAN` is still mandatory** — a durable
  audit trail (the ticket's `history`) and a channel that works even if the
  workspace or tmux session is down — it is simply no longer the *only* way
  back in.
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
- `pr_urls`: `[]` until the PR(s) exist. Normally populated on `phase:
  implement`'s `DONE` — `/implement-issue`'s Phase B step 13 pushes and opens
  them as its own last step. `phase: ship`'s `DONE` also fills this (whether
  confirming what implement already opened, or — the fallback path, a plan
  predating this convention — having opened them itself).
- `question`: the exact question recorded on the ticket's `question` field on
  `NEEDS_HUMAN`, or `null` otherwise.
- `detail`: short free text — documented-default assumptions taken, the
  permission-denial string on `FAILED`, or any other one-liner the wrapper or
  the morning brief should surface. On an `implement` phase `DONE`, this is
  where the **QA artifact's absolute path** goes
  (`docs/plans/qa/<eng-id>-qa.md` in the root worktree — see
  `implement-issue/SKILL.md`'s Phase B step 9): that file, not `detail`, carries the
  relaunch commands, the gates' commit SHA, and the QA checklist, so `detail`
  only needs to point at it rather than duplicate it. Not a substitute for
  `question` or the queue write; both still happen.

## Local queue contract

The private review channel is a local queue: one JSON file per ticket at
`$AP_HOME/queue/<ENG-ID>.json`, read/written exclusively through
`ap_queue.py` (imported directly by the Python pieces; `ap-cycle.sh`/
`ap-resume.sh` shell out to it as
`python3 ap_queue.py --ap-home "$AP_HOME" <cmd> ...`) and through the `ap`
CLI's `queue`/`approve`/`reply`/`retry` subcommands the human runs by hand.
Never post plan content or questions to Linear — Linear is team-visible.

`ap_queue.py` lives next to `ap` in `autopilot/bin/`, but unlike `ap` it is
not itself symlinked onto `PATH` — resolve it from `ap`'s own symlink target
once, then reuse that path: `QUEUE_PY="$(dirname "$(readlink -f "$(command
-v ap)")")/ap_queue.py"`. Every `ap_queue.py` invocation below assumes this
resolution; write it out in full the first time a skill's headless section
needs it, not on every call.

This entirely replaces the old GitHub-repo inbox (one issue per ticket,
state as a label, directives as comments) — there is no `$AP_INBOX_REPO`
anymore, and no `gh issue` call belongs in any of this. Read
`autopilot/bin/ap_queue.py` for the authoritative schema; the summary below
maps each of the inbox's old four roles onto the queue.

- **Schema**, one file per ticket (`ap_queue.py`'s `new_ticket`): `eng_id`,
  `state`, `seq` (monotonic, oldest-first ordering — replaces GitHub issue
  numbers as the time proxy), `created_at`/`updated_at`, `note` (free text
  passed to the plan phase as context, same role the old issue body/title
  suffix had), `auto_approve` (bool, persistent per-ticket auto-approve
  switch — replaces the old `auto` label), `pending_approval` (bool, set by
  `ap approve`, consumed and cleared by the decider), `feedback` (string or
  `null`, set by `ap reply` — serves BOTH plan-revision feedback and a
  needs-input answer; the decider discriminates purely by the ticket's
  current `state`, not by any marker), `feedback_seq` (monotonic, bumped by
  `ap reply` — lets a parked act's tmux window get a fresh reply relayed
  into it via `ap-resume.sh` without a fresh dispatch), `phase_at_question`/
  `question` (set when `state: needs-input`, replaces the old `Phase: X`
  comment), `plan_path`, `pr_urls`, `history` (append-only audit trail:
  `{ts, event, actor}` per transition — the durable record the old inbox's
  comment thread used to be).
- **States** — exactly one held at a time, swapped rather than accumulated:
  `queued`, `planning`, `plan-review`, `needs-input`, `building`, `shipping`,
  `ship-pending`, `ready-to-test`, `failed`, `done`. State machine:
  `queued → planning → plan-review → building → shipping → ready-to-test`,
  with `needs-input`/`failed` reachable from any state. `building` now
  covers the push and PR-open too — `/implement-issue`'s Phase B step 13
  does both as its own last step before writing `DONE` — so by the time
  `shipping` starts the PR(s) already exist; `shipping` now covers only
  `/ship-work`'s own rebase-and-local-gate pass, since it never waits on
  remote CI and never merges. `shipping` is the odd one out: it is set by
  the **orchestrator** (`ap-cycle.sh`), not by a skill, right before it
  invokes the ship phase (`building` → `shipping`) — this makes it reliable
  even if the ship session dies before writing anything.
  `/ship-work --headless` owns the swap out of it (`shipping` →
  `ready-to-test` on success, `shipping` → `needs-input` on a hard stop).
  Every other swap is skill-side, via:
  ```bash
  python3 ap_queue.py --ap-home "$AP_HOME" set <ENG-ID> --state <new-state> \
    --field key=value --event "description"
  ```
  `ship-pending` means implement finished and committed, ship still owed —
  reachable from `shipping` (the orchestrator sets it when a ship phase
  fails for an external cause, see "External failures are re-queued, not
  dead-ended" below) or by a human retrying it by hand (`ap retry`). The
  decider's tier 4 claims it (`ship-pending` → `shipping`) and dispatches
  `/ship-work --headless` (`ship-work` never merges regardless of flags, so
  there is no `--no-merge` to pass anymore) with no `/implement-issue` step
  first — the plan is already committed. This claims the orchestrator's SHIP
  lane (its own slot pool, `AP_SHIP_SLOTS`), not the BUILD lane `implement`
  uses — see "Orchestrator guarantees" below for the port-pair mechanics, and
  `autopilot/README.md`'s concurrency section for why the cap differs.
- **New intake** (was: opening a GitHub inbox issue titled `ENG-<id>` labeled
  `Queued`): the owner runs `ap queue ENG-<id> ["note"] [--auto]`, which
  writes a fresh ticket at `state: queued` (`--auto` also sets
  `auto_approve`). The decider claims `queued` tickets and dispatches the
  plan phase, swapping to `planning`.
- **Plan approval** (was: commenting `go`/`auto` on the inbox issue, or the
  `auto` label): the owner runs `ap approve ENG-<id> [--auto]` on a
  `plan-review` ticket — this sets `pending_approval: true` (and
  `auto_approve: true` too, with `--auto`), which the decider treats exactly
  like the old `go` comment on its next pass, skipping straight to
  `implement`. A **new** `ap reply` (plan feedback) on the same ticket beats
  a stale `pending_approval`/`auto_approve` — the decider checks `feedback`
  before falling back to auto-approval, so it never builds a plan the owner
  just objected to. `needs-input` tickets are **never** auto-approved: a
  blocking question or a ship-phase stop always waits for the human,
  regardless of `auto_approve`.
- **Blocking-question answers** (was: commenting on a `needs-input` inbox
  issue, discriminated by a `Phase: X` first-line marker): the owner runs
  `ap reply ENG-<id> "text"` — this is the same command plan-review feedback
  uses; the decider tells the two apart purely by the ticket's current
  `state` (`plan-review` → feedback, `needs-input` → an answer), so there is
  no marker convention to maintain anymore (see "Loop prevention" below).
- **Ship retries** (was: relabelling the inbox issue back to `ship-pending`
  by hand): `ap retry <target>` re-queues a `FAILED` ticket to the state its
  failed phase started from (`plan`/`replan` → `queued`, `implement` →
  `plan-review`, `ship` → `ship-pending`) — the same restoration an external
  failure already does automatically (below), just human-triggered.
- **External failures are re-queued, not dead-ended.** When an act's own
  stderr/stdout matches a signature that names a cause outside the plan or
  the code — a rate/usage/session limit trip, or the provider itself
  erroring (`overloaded`, `529`, `API Error`) — the orchestrator does not set
  the ticket's state to `failed`. Instead it restores the state the failed
  phase started from, so the same work is picked up again once things clear:
  `plan`/`replan` → `queued`, `implement` → `plan-review`,
  `ship` → `ship-pending`. It records the external cause and the matched
  signature line in the ticket's `history`, and pings with a title like
  `requeued after external failure: <issue>` rather than the usual `FAILED`
  wording. This is entirely orchestrator-side reconciliation, not a skill
  behavior — no skill needs to detect or act on it. The consecutive-
  failure counter (and the usage-limit auto-pause it can trigger) still
  increments for an external failure exactly as it does for any other one —
  that backoff is what stops a re-queue from thrashing.
- **Loop prevention is now structural, not a marker convention.** The old
  inbox was operated with the owner's own `gh` credentials, so a
  pipeline-authored comment and a human comment had the same author — the
  first line (`Plan file:`/`Phase: X`/`Autopilot:`) was the only
  distinguishing signal, and `autopilot-poll` had to read it to decide
  whether new owner input existed; an unmarked comment would be misread as
  the owner speaking and start an unbounded re-plan loop. **That entire
  marker convention is gone and should not be reintroduced or referenced as
  live behavior** — it existed only to disambiguate two humans' worth of
  writes to the same channel, which is structurally impossible now: only a
  human can write `feedback`/`question`/`pending_approval` (via `ap
  approve`/`ap reply`), and only the pipeline writes `state`/`plan_path`/
  `pr_urls`/`history` (via `ap_queue.py set`). There is no channel where an
  agent-authored write could be mistaken for a human one.

## Ask→fallback rule

Wherever an interactive skill's instructions say ask, confirm, or stop and
ask, headless mode resolves it one of two ways:

1. **If that instruction text also documents a default** (an explicit
   ordering, a stated fallback, a "otherwise do X"), take it. Record the
   assumption in `status.json`'s `detail` **and** in the ticket's `history`
   (`ap_queue.py set <ENG-ID> --event "..."`), so a human reviewing later can
   override it. This is not silent: it is a recorded, reversible choice.
2. **Otherwise**, record the question on the ticket (`ap_queue.py set
   <ENG-ID> --state needs-input --field question='"<text>"' --field
   phase_at_question='"plan|implement|ship"' --event "needs input"`), write
   `status.json` with `status: NEEDS_HUMAN` and `question` set to the exact
   text recorded, and end the run.

Never wait for a reply. Never ask in the chat/terminal (there is none to ask
in). Never post a question or plan content to Linear.

## Linear footprint

Headless runs never post a Linear comment — not ever, for any reason.
Questions, plan content, PR links, QA notes, and relaunch commands all go to
the local queue ticket only (see the local queue contract above); Linear is
team-visible and the notify channel plus the local queue are the only places
a headless run talks to a human. The entire headless footprint on Linear is
exactly two writes:

- **Claim** (on first touching an issue): `assignee: me`, `state: In
  Progress`.
- **Ship success**: label `agent:ready-to-test` — no comment. The PR link(s)
  go to the ticket's `pr_urls` only.

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
- The `building` → `shipping` queue-state swap happens before the ship phase
  is invoked (see "States" above) and the "shipping: `<issue>`" phone
  ping fires at the same time — both wrapper-side, not skill-side, so they
  happen even if the ship session dies before writing anything.
- Reconciliation of `FAILED` or crashed runs (missing `status.json`) — a
  skill never needs to self-handle a crash; it only needs to write
  `status.json` on every path it controls.
- The phone ping on `NEEDS_HUMAN` and `FAILED`.

A skill's headless section is responsible for reaching one of the three
terminal states and writing `status.json` honestly; everything after that is
the wrapper's job.
