# Headless protocol

The phase-agnostic core of every headless pipeline `ap` drives — today the
legacy feature-path skills (`/implement-issue`'s `--phase plan`/`--phase
implement`, and `/ship-work`), and the `piv-*` bug-path skills. Read this
before reading any skill's own headless section: it defines the vocabulary
and mechanics once so each skill only states what maps to what. What is
*not* here — a pipeline's own state names, its state machine, and its
orchestrator-side port/lane guarantees — lives in that pipeline's own
addendum (`autopilot-protocol.md` for the legacy feature path).

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

- One command per Bash call. Never pipe to `jq`/`python3`/`head`. `jq`
  resolves via `~/.nix-profile/bin` for a shell that sourced the user's
  profile, but a cron-launched act's `PATH` inheritance is not guaranteed —
  so prefer `gh --jq` and `python3` over `jq`, and where a skill has a hard
  `jq` dependency it must preflight `command -v jq` and FAIL fast. For JSON
  from `gh`, use its built-in `--jq` flag (`gh issue list --json
  number,title,labels --jq '...'`), which needs no pipe.
- Prefer the allowed GitHub MCP issue tools (`list_issues`, `issue_read`,
  `issue_write`, `add_issue_comment`) over `gh` when one fits.
- A permission denial is not a prompt: nobody will answer. Retry once with an
  allowed form; if still denied, treat it per this protocol (FAILED with the
  denial string in `detail`) rather than asking in chat.

## Status vocabulary

- `DONE` — the phase finished; whatever it was supposed to produce (a
  committed plan, a committed RCA, a QA'd branch, an open PR) exists.
- `NEEDS_HUMAN` — the run cannot proceed without the issue owner; a question
  has been recorded on the ticket's local queue entry (`state: needs-input`,
  `question` set). What happens to the *process* next is the wrapper's call
  — see "## Parking" — not something a skill's own instructions decide or
  need to know.
- `FAILED` — an error stopped the run. No in-run retry; the wrapper decides
  whether and when to retry.

## Parking

`AP_ACT_LAUNCH_MODE=persistent` (the default) launches every headless act —
any phase, any pipeline, standalone or chained — as a real interactive
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
  lock immediately, so the pipeline's limited slot pools aren't tied up for
  however long the owner takes to reply — the exact property `oneshot`
  mode's "NEEDS_HUMAN frees the slot" already had, preserved here by a
  different mechanism.
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
  new invocation that re-derives context from the artifact file (and kata).
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
  "phase": "<the phase name this pipeline uses for this act>",
  "artifact_path": "<abs path or null>",
  "pr_urls": [],
  "question": "<string or null>",
  "detail": "<short free text: assumptions, the QA artifact path, denial strings>"
}
```

- `issue`: the Linear id the run acted on, `ENG-<n>` form.
- `phase`: the phase name this pipeline uses for this act — see "## Pipelines
  and their phase vocabularies" below for each pipeline's phase set.
- `artifact_path`: absolute path to the run's primary durable artifact (a
  committed plan, a committed RCA, a report), or `null` if none exists yet
  (e.g. a `FAILED` run that never reached the write).
- `pr_urls`: `[]` until the PR(s) exist. Normally populated on the
  fix/implement phase's `DONE` — the fix/implementation step pushes and
  opens them as its own last step. The review/ship phase's `DONE` also fills
  this (whether confirming what the earlier phase already opened, or —
  the fallback path — having opened them itself).
- `question`: the exact question recorded on the ticket's `question` field on
  `NEEDS_HUMAN`, or `null` otherwise.
- `detail`: short free text — documented-default assumptions taken, the
  permission-denial string on `FAILED`, or any other one-liner the wrapper or
  the morning brief should surface. On an implement-shaped phase's `DONE`,
  this is where the **QA artifact's absolute path** goes
  (`docs/plans/qa/<eng-id>-qa.md` in the root worktree): that file, not
  `detail`, carries the relaunch commands, the gates' commit SHA, and the QA
  checklist, so `detail` only needs to point at it rather than duplicate it.
  Not a substitute for `question` or the queue write; both still happen.

**No orchestrator code reads either `phase` or `artifact_path` out of this
file** (verified: `ap-cycle.sh` takes the artifact path from the decider's
own resolution, `ap-resume.sh` from the parked registry, `ap-runs.py show`
dumps the file verbatim). So the feature path may keep emitting `plan_path`
alongside `artifact_path` until a later migration removes it, and both keys
coexisting is harmless — this file's shape is for the human and the morning
brief, not for orchestrator logic.

## Local queue contract

The private review channel is a local queue: one JSON file per ticket at
`$AP_HOME/queue/<ENG-ID>.json`, read/written exclusively through
`ap_queue.py` (imported directly by the Python pieces; `ap-cycle.sh`/
`ap-resume.sh` shell out to it as
`python3 ap_queue.py --ap-home "$AP_HOME" <cmd> ...`) and through the `ap`
CLI's `queue`/`approve`/`reply`/`retry` subcommands the human runs by hand.
Never post plan content, RCA content, or questions to Linear — Linear is
team-visible.

`ap_queue.py` lives next to `ap` in `autopilot/bin/`, but unlike `ap` it is
not itself symlinked onto `PATH` — resolve it from `ap`'s own symlink target
once, then reuse that path:
```bash
QUEUE_PY="$(dirname "$(readlink -f "$(command -v ap)")")/ap_queue.py"
```
Every `ap_queue.py` invocation in a skill's headless section assumes this
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
  passed to the first phase as context, same role the old issue body/title
  suffix had), `auto_approve` (bool, persistent per-ticket auto-approve
  switch — replaces the old `auto` label), `pending_approval` (bool, set by
  `ap approve`, consumed and cleared by the decider), `feedback` (string or
  `null`, set by `ap reply` — serves BOTH revision feedback and a
  needs-input answer; the decider discriminates purely by the ticket's
  current `state`, not by any marker), `feedback_seq` (monotonic, bumped by
  `ap reply` — lets a parked act's tmux window get a fresh reply relayed
  into it via `ap-resume.sh` without a fresh dispatch), `phase_at_question`/
  `question` (set when `state: needs-input`, replaces the old `Phase: X`
  comment), `plan_path`, `pr_urls`, `history` (append-only audit trail:
  `{ts, event, actor}` per transition — the durable record the old inbox's
  comment thread used to be). Each pipeline's own addendum documents its own
  state set — states are not repeated here; see "## Pipelines and their
  phase vocabularies" below for the full picture across pipelines.
- **New intake** (was: opening a GitHub inbox issue titled `ENG-<id>` labeled
  `Queued`): the owner runs `ap queue ENG-<id> ["note"] [--auto]`, which
  writes a fresh ticket at `state: queued` (`--auto` also sets
  `auto_approve`). The decider claims `queued` tickets and dispatches the
  first phase.
- **Plan/draft approval** (was: commenting `go`/`auto` on the inbox issue, or
  the `auto` label): the owner runs `ap approve ENG-<id> [--auto]` on a
  review-state ticket — this sets `pending_approval: true` (and
  `auto_approve: true` too, with `--auto`), which the decider treats exactly
  like the old `go` comment on its next pass, skipping straight to the next
  phase. A **new** `ap reply` (revision feedback) on the same ticket beats
  a stale `pending_approval`/`auto_approve` — the decider checks `feedback`
  before falling back to auto-approval, so it never builds on top of
  something the owner just objected to. `needs-input` tickets are **never**
  auto-approved: a blocking question or a later-phase stop always waits for
  the human, regardless of `auto_approve`.
- **Blocking-question answers** (was: commenting on a `needs-input` inbox
  issue, discriminated by a `Phase: X` first-line marker): the owner runs
  `ap reply ENG-<id> "text"` — this is the same command review-phase
  feedback uses; the decider tells the two apart purely by the ticket's
  current `state`, so there is no marker convention to maintain anymore (see
  "Loop prevention" below).
- **Retries** (was: relabelling the inbox issue back to a pending state by
  hand): `ap retry <target>` re-queues a `FAILED` ticket to the state its
  failed phase started from — the same restoration an external failure
  already does automatically (below), just human-triggered. Each pipeline's
  own addendum documents its own retry-state map.
- **External failures are re-queued, not dead-ended.** When an act's own
  stderr/stdout matches a signature that names a cause outside the plan/RCA
  or the code — a rate/usage/session limit trip, or the provider itself
  erroring (`overloaded`, `529`, `API Error`) — the orchestrator does not set
  the ticket's state to `failed`. Instead it restores the state the failed
  phase started from, so the same work is picked up again once things clear.
  It records the external cause and the matched signature line in the
  ticket's `history`, and pings with a title like `requeued after external
  failure: <issue>` rather than the usual `FAILED` wording. This is entirely
  orchestrator-side reconciliation, not a skill behavior — no skill needs to
  detect or act on it. The consecutive-failure counter (and the usage-limit
  auto-pause it can trigger) still increments for an external failure
  exactly as it does for any other one — that backoff is what stops a
  re-queue from thrashing.
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
   phase_at_question='"<phase name>"' --event "needs input"`), write
   `status.json` with `status: NEEDS_HUMAN` and `question` set to the exact
   text recorded, and end the run.

Never wait for a reply. Never ask in the chat/terminal (there is none to ask
in). Never post a question or plan/RCA content to Linear.

## Linear footprint

Headless runs never post a Linear comment — not ever, for any reason.
Questions, plan/RCA content, PR links, QA notes, and relaunch commands all go
to the local queue ticket only (see the local queue contract above); Linear
is team-visible and the notify channel plus the local queue are the only
places a headless run talks to a human. The entire headless footprint on
Linear is exactly two writes:

- **Claim** (on first touching an issue): `assignee: me`, `state: In
  Progress`.
- **Ship/review success**: label `agent:ready-to-test` — no comment. The PR
  link(s) go to the ticket's `pr_urls` only.

Never set `Staging` or `Done` headlessly — `Staging` means merged
(`AGENTS.md`), and merging is never autonomous. Never create a Linear issue
headlessly; the free-text-creation path is interactive-only, since it depends
on an ask that has no headless-safe default.

The bug path's Linear footprint is identical — claim + `agent:ready-to-test`
label, never a comment. `mcp__linear-server__save_comment` is **not** on the
allow list, so `piv-investigate-issue`'s Linear-comment step is structurally
impossible headlessly, not merely forbidden by this rule.

## Never end the turn with required local work in the background

The headless `-p` harness kills the session outright once its
background-wait ceiling passes: no final message, no `status.json`, and the
wrapper reconciles a healthy-but-slow run as a crash. Run the quality gates
and any other CI-adjacent waits as **blocking foreground commands**, never
parked as background tasks you "wait on," and treat writing `status.json` as
the last thing that must complete before anything else is allowed to still
be running. If a suite genuinely cannot finish inside the turn, write an
interim `status.json` (`FAILED`, `detail: "gates still running at turn
end"`) first and let the retry recover — never leave the file unwritten
while waiting.

**This rule does not apply to dispatching a sub-agent via the `Agent` tool**
(a `plan-critic`/`red-team`/`challenge` audit, a Codex second draft, or any
other fresh-agent dispatch a skill's own steps call for). Ending the turn
right after such a dispatch is the *correct* move, not a risk to guard
against: the background-wait ceiling above is specifically about a literal
shell command the model is synchronously blocking on (a test suite run as a
foreground `Bash` call); an `Agent` dispatch is not that — it returns
immediately, and its result arrives as an ordinary later message in the
*same* session (interactive or a persistent-mode tmux window alike), which
the harness delivers and resumes on its own, no ceiling involved. **Do not
write an interim `status.json` after dispatching a sub-agent and stop
there** — doing so is actively harmful, not merely unnecessary: the wrapper
in `ap-cycle.sh` treats a `FAILED`/`DONE` `status.json`'s mere existence as
the act being finished and tears the window down within a few seconds,
which permanently cuts off the dispatch's own notification before it can
ever arrive — turning a run that would have completed successfully into a
guaranteed, wasted failure. Just end the turn with nothing written; the
next message (the dispatch's result) continues the same run normally.
Caught live on `ENG-1594`'s `piv-investigate-issue` run on 2026-09-04:
step 7's red-team/challenge dispatch led the act to (mistakenly) treat a
now-deprecated `TaskOutput` tool as the only way to retrieve the result,
concluded it therefore "must await the notification" — correctly — but then
wrote an interim `FAILED` status.json anyway "to be safe," which is exactly
what got the run killed before that notification could land.

## Pipelines and their phase vocabularies

| pipeline | selected by | phases (`status.json`'s `phase`) | states | lanes |
|---|---|---|---|---|
| legacy feature (**retired, inert once the feature fork ships**) | never dispatched after the feature-fork plan; reachable only by hand-setting a state | `plan`, `replan`, `implement`, `ship` | `planning`, `plan-review`, `building`, `shipping`, `ship-pending` | plan, build, ship |
| piv — bug | `kind: bug` | `investigate`, `re-investigate`, `fix`, `review` | `piv-drafting`, `piv-draft-review`, `piv-implementing`, `piv-review-pending`, `piv-reviewing` | plan, build, review |
| piv — feature | `kind: feature` (or absent) | `design`, `redesign`, `build`, `review` | *(the same five)* | plan, build, review |

Shared states: `queued`, `needs-input`, `ready-to-test`, `failed`, `done`.
The invariants that keep three pipelines coexisting auditable:

- **(a)** the piv state set and the legacy state set are disjoint, so a
  legacy-state ticket can only ever be claimed by legacy tiers and vice
  versa.
- **(b)** `kind` is read in exactly two places — the `queued` intake tier
  and the `piv-draft-review` tier, the only two states where both kinds sit
  and the next action differs.
- **(c)** phase names are globally unique across all three pipelines, which
  is what lets `phase_at_question` route decider tiers by phase alone, and
  what lets a retry-state map stay a flat lookup.

Until the feature fork ships, the middle row is the only piv row in
production and the third row is aspirational — this document is written so
that lands as a state-machine no-op when it does.

## Phase-name constraint

A phase name must contain **no underscore** — `ap-runs.py`'s
`_ACT_WINDOW_RE` uses `(?P<phase>[^_]+)` against an underscore-delimited
window name, so a phase named `re_investigate` would silently stop `ap
runs`/`ap status`/`ap tail` from seeing the act. Hence `re-investigate`, not
`re_investigate`.
