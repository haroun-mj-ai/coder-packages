# Autopilot

A 24/7 scheduler that runs one pipeline, two kinds, headlessly on this Coder
workspace: every ticket enters `queued`, then runs (`design` for a feature /
`investigate` for a bug) → `piv-draft-review` (a human approval gate) →
(`build` / `fix`) → `piv-review-pending` → `review` → `ready-to-test`, so
that Haroun's own touchpoints shrink to: queue an issue, review the plan or
RCA privately from his phone, test the result, and merge. It never merges
anything itself — that gate stays human, every cycle, forever. (The original
`/implement-issue --phase plan` → `/implement-issue --phase implement` →
`/ship-work` chain this pipeline replaced is retired but left in the tree —
see "Retired: the legacy plan/implement/ship chain" below.)

## Install

```bash
cd coder-packages
./scripts/install-autopilot.sh          # idempotent, safe to re-run
./scripts/install-autopilot.sh --check  # report convergence, change nothing
```

This installs `tmux` and `supercronic` if missing, creates
`~/.autopilot/{runs,briefs,logs}` (`~/.autopilot/queue/` — the local queue,
one JSON file per ticket — is created lazily by `ap_queue.py` on first use),
seeds `~/.autopilot/env` (only if absent — never overwritten), symlinks
`autopilot/bin/*` into `~/.local/bin`,
adds a managed self-heal block to `~/.bashrc` that runs `ap up --quiet` on
every interactive login, and wires the skills this feature runs
(`implement-issue` — superseding the retired `plan-issue`/`implement-plan`
stubs, kept symlinked only so a stale invocation fails informatively —
`ship-work`, `daily-brief`, `autopilot-protocol.md`) as symlinks into
the JourneyAI checkout
(`AP_WORK_REPO`, default `/home/coder/root-for-local`) — see "A note on
`coder-packages/claude/skills/`" below.

## Configure `~/.autopilot/env`

The installer seeds this file with commented defaults; uncomment and fill in
what you need:

- `NTFY_TOPIC` — an unguessable topic string on [ntfy.sh](https://ntfy.sh).
  No account required: pick a random slug (e.g. `openssl rand -hex 16`) and
  subscribe to `https://ntfy.sh/<topic>` from the ntfy mobile app to receive
  pings.
- `SLACK_WEBHOOK_URL` — an "Incoming Webhook" URL from a Slack app
  (create one at <https://api.slack.com/apps> → your app → *Incoming
  Webhooks* → *Add New Webhook to Workspace*).
- `AP_MAX_ISSUES_PER_DAY` (default `3`) / `AP_MAX_DAY_COST_USD` (default
  `50`) — per-rolling-day budget caps, checked against
  `~/.autopilot/runs/YYYY-MM-DD.jsonl`.
- `AP_TZ` (default `UTC`) — timezone used for day boundaries (ledger,
  crontab, budget resets).
- `AP_PLAN_SLOTS` (default `1`, clamped `1`-`4`) — concurrent plan-lane acts
  (`design`/`redesign`/`investigate`/`re-investigate`, plus the retired
  `plan`/`replan`). Every ticket, of either kind, passes through this lane
  at intake, so its default of `1` is the pipeline's tightest bottleneck
  (see `ap-env.sh`'s ENG-1407 comment) — see "Plan lane load after the
  cutover" below for the recommended rollout step.
- `AP_BUILD_SLOTS` (default `2`, clamped to `1`-`4`) — concurrent `build`
  (feature) / `fix` (bug) acts, plus the retired implement→ship chain. Safe
  here specifically because backend tests run on mongomock (in-memory,
  per-test, never shared) and every build works in its own git worktree. See
  "Concurrent builds" below.
- `AP_SHIP_SLOTS` (default `3`, clamped to `1`-`6`) — concurrent *standalone*
  ship-only retries (its own lane, separate from `AP_BUILD_SLOTS`).
  **Retired** — see "Retired: the legacy plan/implement/ship chain" below;
  no ticket of either kind can produce `ship-pending` any more, so this lane
  never claims work. Kept documented here because the code, locks and ports
  all stay in the tree until a later cleanup plan removes them.
- `AP_REVIEW_SLOTS` (default `2`, clamped `1`-`4`) — concurrent
  `piv-review-pr` acts (its own **review** lane, separate from plan/build/
  ship), for either kind's PR. See "Concurrent builds" below.
- Model overrides, all optional, all falling back to a sane per-phase
  default: `AP_INVESTIGATE_MODEL` / `AP_FIX_MODEL` / `AP_REVIEW_MODEL` (bug
  path plus the shared review act) and `AP_DESIGN_MODEL` / `AP_BUILD_MODEL`
  (feature path) pin the model used for their respective act. Unset,
  investigation/design run on `opus` (judgment-heavy: RCA synthesis or
  strategic design reasoning, the adversarial gate, the audit) and
  fix/build/review run on `sonnet` (execution-heavy: a settled artifact is
  being implemented, or delegated review scripts are doing the heavy
  reasoning in their own lanes).
- `AP_LIMIT_COOLDOWN_MIN` (default `60`) — minutes a usage-limit auto-pause
  (see "Two consecutive failures" below) waits before clearing itself. `0`
  disables auto-resume entirely, so every pause then waits for a human,
  same as before this existed.
- `AP_ACT_LAUNCH_MODE` (default `persistent`) — `persistent` runs every act
  as a real interactive `claude` session in its own tmux window, so a
  mid-run blocking question parks alive (`tmux attach -t autopilot` to
  answer it directly) instead of ending the run; `oneshot` restores the
  original `claude -p` behavior. See "Persistent sessions and parking"
  below.

At least one of `NTFY_TOPIC` / `SLACK_WEBHOOK_URL` must be set for pings to
actually go anywhere; unconfigured, `ap-notify.sh` just logs to
`~/.autopilot/logs/notify.log`.

## Daily flow

1. **Queue it**: `ap queue ENG-1234 ["optional note"] [--kind feature|bug]`
   (default `feature`) from anywhere on this workspace. Autopilot claims it
   (Linear assignee + `In Progress`) and drafts it on the next cycle (every
   cycle is a decision pass now — see "The decider" below).
2. **Review privately.** The full plan or RCA markdown is committed to the
   branch as always; the ticket's `artifact_path` field points at it and its
   state moves to `piv-draft-review`. A phone ping tells you it's ready —
   `ap sessions` (or `ap run <eng-id>`) shows it.
3. **Approve or give feedback**:
   - `ap approve ENG-1234` to approve — the very next cycle claims it and
     starts building/fixing. `ap approve ENG-1234 --auto` also flips this
     ticket's persistent auto-approve switch, so future draft phases on it
     skip this step entirely (unless you `ap reply` with objecting feedback
     first).
   - `ap reply ENG-1234 "..."` for anything else — treated as feedback: the
     next cycle re-drafts in place, quoting your text.
4. **Build/fix happens unattended**, on one of `AP_BUILD_SLOTS` (default
   `2`) concurrent build slots, each with its own frontend/backend port pair
   (`5173+n`/`8000+n` for slot `n`; the human's own `5173`/`8000` are never
   assigned to a slot) — see "Concurrent builds" below. The ticket's state
   swaps to `piv-review-pending` the moment the build/fix act finishes
   (with its own ping) — no chain into review: a later cycle claims the
   review lane separately. Headless autopilot never comments on Linear: the
   claim and the `agent:ready-to-test` label are its only Linear writes;
   everything else (PR links, notes, relaunch commands) lands on the local
   queue ticket.
5. **Review happens unattended**, on one of `AP_REVIEW_SLOTS` concurrent
   review slots: `piv-review-pr` dispatches `debate-review`, then hands off
   to `babysit-pr` for round-based bot-review triage. You get a "ready to
   test" ping with the PR link and the exact relaunch commands (worktree
   paths, ports) once review is worked to resolution — also recorded on the
   ticket's `pr_urls`.
6. **Morning:** run `/test-issue` (or the relaunch commands from `ap
   sessions`), test against the running servers, and once CI is green,
   merge it yourself (GitHub UI or `gh pr merge` — autonomous merging is
   permanently out of scope). Archiving the plan/RCA under
   `docs/plans/completed/` and the rest of closeout (Linear `Staging`, kata
   close, worktree removal, and setting the ticket's state to `done`)
   happens after that merge.

A daily brief (`ap-brief.sh`, 07:00 `AP_TZ` by default) pings a digest of
what's awaiting approval, ready to test, needs input, or failed, plus cost vs
budget and any scheduler gap.

### The decider

`ap-cycle.sh` fires every minute and, unlike the old haiku poll, decides
every single cycle unconditionally — there is no gate to wake it, because
deciding is now $0 and purely mechanical: a queue-file read, a state check,
an exact-word match, a regex, a priority ordering, or a queue write. There is
no GitHub inbox and no Linear polling for intake either — the only intake
path is `ap queue ENG-<id> [--kind feature|bug]`, run by hand. `ap-decide.py`
(invoked via `ap-decide.sh`) reads `$AP_HOME/queue/*.json`, applies its
tiers in priority order, and either claims the highest-priority actionable
ticket (a queue state write) or returns `action: none` for that cycle.

**One pipeline, two kinds.** Every ticket, whatever its `kind`, runs the same
shape: `queued` → (`design` for a feature / `investigate` for a bug) →
`piv-draft-review` (a human approval gate) → (`build` / `fix`) →
`piv-review-pending` → `review` → `ready-to-test`. The five non-terminal
states in that chain — `piv-drafting`, `piv-draft-review`,
`piv-implementing`, `piv-review-pending`, `piv-reviewing` — are **shared by
both kinds**: a feature's plan and a bug's RCA are both "a draft pending a
human's approval," which is exactly what `piv-draft-review` means for
either. `kind` is read in exactly two places — the `queued` intake tier
(which act to dispatch, `design` or `investigate`) and the `piv-draft-review`
tier (which act to dispatch next, `build` or `fix`) — the only two states
where both kinds sit and the next action differs. Every other tier is
determined by state alone (the stale sweep) or by *phase* alone
(`design`/`build` are feature-only phase names, `investigate`/`fix` are
bug-only, so `phase_at_question` already encodes the kind without a `kind`
read). Both kinds ride the same three lanes — plan, build, review — in
"Concurrent builds" below. The legacy `/implement-issue`/`/ship-work` chain
this replaced is retired but not deleted; see "Retired: the legacy
plan/implement/ship chain" below.

### Retired: the legacy plan/implement/ship chain

Since the cutover to "one pipeline, two kinds" above, no decider tier ever
emits `plan`, `replan`, `implement`, or `ship` again, and no ticket of
either kind can produce `ship-pending` any more. `planning`/`plan-review`/
`building`/`shipping`/`ship-pending` are only reachable by hand-setting a
ticket's state via `ap sessions [s]` — a deliberate manual escape hatch,
kept live on purpose while the piv pipeline is unproven in production, not
an oversight. Nothing here is deleted: `/implement-issue`'s
`plan`/`replan`/`implement` dispatch arms, `/ship-work`'s `ship` arm, the
implement→ship chain in both `ap-cycle.sh` and `ap-resume.sh`, and the five
legacy states all stay byte-identical in the tree. A later, separate cleanup
plan removes them once both piv forks are proven in production.

One consequence is total: **the entire ship lane is dead.** Since no ticket
can reach `ship-pending` any more, a standalone ship-only retry can never be
dispatched, so `AP_SHIP_SLOTS`, `lock.ship.1`..`lock.ship.N`, ports
`5181`-`5186`/`8011`-`8016`, `ap down`'s ship-lane refusal, `ap status`'s
ship slot line, and `ap limits --ship-slots` are all unreachable code paths
now. They stay in the tree, annotated `(dead — see "Retired" above)` at each
of the spots documented below — removing them is a later cleanup plan's job,
not this one's.

### Ship-only retry (retired)

**Retired — see "Retired: the legacy plan/implement/ship chain" above. Kept
verbatim below for reference; the ship lane it describes can no longer be
reached by any ticket.**

Sometimes `implement` succeeds — the code is committed — and only the ship
phase fails (an external cause such as a session/rate limit trip, or a hard
CI stop). Re-running the whole `implement → ship` chain would be wasteful and
risk re-doing already-good work, so the pipeline retries just the ship: the
queue state `ship-pending` means "implement committed, ship still owed" —
set by the orchestrator when a ship phase fails for an external cause (see
"Two consecutive failures" below), or reachable by `ap retry <target>`
(human-triggered). The next cycle claims it (`ship-pending` → `shipping`) and
dispatches
`/ship-work --headless` directly (there is no `--no-merge` flag anymore —
`ship-work` never merges, so nothing needs disabling), with no plan or implement step
first. It claims its own **ship lane** slot (`AP_SHIP_SLOTS`, default `3`) —
deliberately *not* a build slot: a standalone ship is almost pure CI-wait, so
it must never queue behind a busy build lane. This is distinct from the ship
half of an implement→ship chain, which stays on the build slot it already
holds for the whole chain. See "Concurrent builds" below.

### The bug path

`ap queue --kind bug` classifies a ticket as a bug at intake (default is
`feature`); everything downstream of that one field is what lets the two
kinds' pipelines line up exactly. Three acts, mirroring the three lanes:
`investigate` on the plan lane (RCA + a conditional `/red-team`/`/challenge`
adversarial gate, producing a committed RCA, no ports); `fix` on the build
lane with its own port pair (`piv-implement-issue` + `piv-commit` +
`piv-create-pr` in one act); `review` on the review lane (`piv-review-pr`,
which dispatches `debate-review` then hands off to `babysit-pr` for
round-based bot-review triage). The five states a bug ticket moves through —
`piv-drafting` → `piv-draft-review` → `piv-implementing` →
`piv-review-pending` → `piv-reviewing` — are the same five a feature ticket
moves through; the two kinds' states aren't a second parallel set, they're
the one set described in "The decider" above. What's disjoint is the legacy
five (`planning`/`plan-review`/`building`/`shipping`/`ship-pending`): a
legacy-state ticket can only ever be claimed by a legacy tier, and a
piv-state ticket only by a piv tier, by construction.

### Plan lane load after the cutover

After the feature-fork cutover, **100% of tickets — both kinds — enter
through the plan lane** (`ap-decide.py`'s intake tier): every one of them
runs a long opus-driven design/investigate act with sub-agent fan-out, a
`plan-critic` audit, and a Codex second draft. `AP_PLAN_SLOTS` still
defaults to `1`, which was already the pipeline's tightest artificial
bottleneck (the ENG-1407 case recorded in `ap-env.sh`) — now that it's the
*only* front door for every ticket, that bottleneck bites harder.
Recommended at cutover: `ap limits --plan-slots 2`. The shipped default is
intentionally left unchanged.

## Persistent sessions and parking

`AP_ACT_LAUNCH_MODE` (default `persistent`) controls how `ap-cycle.sh`
launches every act: a real interactive `claude` session in its own tmux
window inside the `autopilot` session, instead of a one-shot `claude -p`. The
practical difference shows up when an act hits a genuine mid-run blocking
question (not the draft-review `go`/feedback gate above, which stays exactly
as described — there's no live process to keep for that, the drafting phase
already exited cleanly after committing its artifact):

- The window **parks alive** instead of the process exiting. Its lane slot
  and per-issue lock are released immediately, so a question that takes you
  hours to answer doesn't tie up one of the pipeline's build slots for that
  whole time.
- **Reply from your phone**, same as always — `ap reply ENG-1234 "..."` gets
  relayed into the parked session automatically (`ap-cycle.sh`'s
  `scan_parked_replies` notices the ticket's `feedback_seq` advanced and
  backgrounds `ap-resume.sh`, which re-acquires a slot and injects the reply
  via `tmux send-keys`).
- **Or reply at the workspace**: `tmux attach -t autopilot`, find the window
  (named `act_<lane>[_<slot>]_<issue>_<phase>` — `ap status` lists parked
  acts, `ap runs`/`ap run <target>` show `PARKED` instead of `LIVE`), and type
  the answer directly. A background sweep notices the resulting state change
  and reconciles the locks/registry the same way a relayed reply would.
- `ap down` refuses while anything is parked (same as it already refuses
  while a lane is busy) — `ap down --force` to kill parked sessions anyway.

Set `AP_ACT_LAUNCH_MODE=oneshot` to restore the original behavior exactly: a
`claude -p` process that exits on any terminal state (including a blocking
question), with a later reply always starting a fresh invocation instead of
resuming a live one.

`persistent` mode has no `-p --output-format json` blob to read
`total_cost_usd` from, so its ledger rows' `cost` column is an **estimate**,
not the billed figure: `ap-cycle.sh`/`ap-resume.sh` resolve the act's session
id from its tmux pane's pid and call `ap-runs.py cost <session-id>`, which
sums that session's own transcript usage (including subagents, priced at
their own model) against published per-Mtok rates (`MODEL_PRICING` in
`bin/ap-runs.py`). It's priced per request at the model that request
actually ran on, so a session mixing a pinned main model with a cheaper
subagent model is not misattributed to one rate — an unrecognized model name
is left out of the total and reported to `cycle.log` rather than guessed at.
Cache-write tokens are priced at the 1h/5m rate Anthropic actually billed
(from the transcript's own `cache_creation` breakdown), falling back to the
5m rate only when a transcript predates that breakdown. This is still an
estimate, not the ground truth `-p` mode gets directly from the API — treat
`ap status`'s week-cost tracking as approximate for any act that ran in
`persistent` mode, `oneshot` mode has no such gap.

## Concurrent builds (and ships)

Four lanes, each its own mutual-exclusion mechanism under `~/.autopilot`
(the ship lane is dead — see "Retired: the legacy plan/implement/ship
chain" above — but kept documented since its code and locks stay in the
tree):

| lane   | slots                             | default cap    | what runs there |
|--------|-----------------------------------|-----------------|------------------|
| plan   | `lock.plan.1` .. `lock.plan.N`    | `AP_PLAN_SLOTS`, default `1`, clamped `1`-`4` | `design`/`redesign` (feature), `investigate`/`re-investigate` (bug) — plus the retired `plan`/`replan` |
| build  | `lock.build.1` .. `lock.build.N`  | `AP_BUILD_SLOTS`, default `2`, clamped `1`-`4` | `build` (feature), `fix` (bug) — plus the retired `implement` and the ship half of a (now unreachable) implement→ship *chain* |
| review | `lock.review.1` .. `lock.review.N` | `AP_REVIEW_SLOTS`, default `2`, clamped `1`-`4` | `piv-review-pr` (`debate-review` + `babysit-pr`) for a piv-path PR, either kind |
| ship   | `lock.ship.1` .. `lock.ship.N`    | `AP_SHIP_SLOTS`, default `3`, clamped `1`-`6` | **(dead — see "Retired" above)** a *standalone* ship-only retry (`action:ship` from a `ship-pending` issue) — unreachable now that no ticket can produce `ship-pending` |

The build lane lets several build/fix acts run at once — safe in this repo
specifically, not in general: backend tests run on mongomock (in-memory,
created fresh per test), so concurrent `pytest` runs never share a database,
and every build works in its own git worktree, so concurrent implementers
never touch the same checkout. Each build slot gets a dedicated
frontend/backend port pair, `5173+n`/`8000+n` for slot `n` (`n` starts at
`1`, so the human's own `5173`/`8000` baseline pair is never handed to a
slot).

The ship lane was capped *higher* than the build lane deliberately: a
standalone ship act is almost pure waiting on GitHub CI — it starts no dev
servers and barely touches the machine — so many could be in flight with
negligible added load, and it had to never queue behind a full build lane
(that was the bug this lane existed to fix). Each ship slot got its own port
pair too, `5180+n`/`8010+n` for slot `n`, deliberately non-overlapping with
both the build base and the human's baseline. This reasoning is now
historical — see "Retired: the legacy plan/implement/ship chain" above; the
ship lane can no longer be dispatched into at all.

The review lane is capped like the build lane, not like the (dead) ship
lane: a review act isn't pure CI-wait like a standalone ship retry was — it
drives `debate-review`'s own sub-agent lanes and `babysit-pr`'s
repair/triage rounds, which touch real compute for 20-60 minutes at a
stretch, so `AP_REVIEW_SLOTS` takes the same `2` default and `1`-`4` clamp
as the build lane rather than the ship lane's higher, near-free cap. Each
review slot gets its own port pair too, `5187+n`/`8020+n` for slot `n`,
non-overlapping with the plan lane, the build lane's `5173+n`/`8000+n`, the
(dead) ship lane's `5181-5186`/`8011-8016`, and the human's own baseline
pair — `piv-review-pr` serves no UI itself, but a fix/build act's
reproduction servers may still be up on the build lane's ports when review
starts on the same ticket, so the review lane needs its own non-colliding
range regardless.

Every lane is reported busy to the poll only when every slot in it is full
(lowest-numbered free slot wins, per lane); the orchestrator tells the
headless session its assigned ports as literal prompt text, `--ports
fe=<port>,be=<port>`, the same mechanism as `--run-dir`.

## Controls

```bash
ap up        # start the tmux session running supercronic (idempotent)
ap down      # stop it
ap status    # tmux liveness, pause state (+ reason), plan/build/review slot
             # occupancy, last 3 ledger lines, gap warning
ap pause     # writes ~/.autopilot/pause (reason "manual", never auto-clears)
ap resume    # rm the pause file, reset the consecutive-failure counter
```

The pause file (`~/.autopilot/pause`) is the one-command override for
anything invasive you're about to do by hand — it does not touch an act
already in flight (the flock is per-slot), but no new cycle starts while it
exists. Autopilot also auto-pauses itself (with a ping) after 2 consecutive
`FAILED` cycles. `ap down` refuses (unless `--force`d) while any plan slot,
any build slot, any review slot, or any (dead, but still lock-checked) ship
slot is occupied, for the same "would kill an act in flight" reason.

Budgets are the other brake: `AP_MAX_ISSUES_PER_DAY` and
`AP_MAX_DAY_COST_USD` in `~/.autopilot/env`, checked against the day's ledger
before every acting cycle.

## Deciding (`ap decide`)

```bash
ap decide     # runs the decider (ap-decide.sh --dry-run) against the
              # REAL local queue, no writes, and pretty-prints the
              # decision plus a one-line reason per tier it evaluated
```

`ap-decide.py` (invoked via `ap-decide.sh`) is the only decision path — there
is no model-based alternative anymore, no haiku call, and nothing to flip
between: every tier is mechanical (a queue-state read, an exact-field check,
a regex, a priority ordering, or a queue write), so it's free and
deterministic every cycle. It never touches Linear (no credential available
to it — the Linear claim on the intake tier happens inside the headless
drafting skill itself, at the start of its run).
Use `ap decide` any time you want to see what the next cycle would do
without risking a write.

## Troubleshooting

- **Permission denials under `dontAsk`:** an acting run fails fast (`FAILED`),
  and the denial string lands both in the ticket's `history` and in the
  day's ledger line. This is the expected tightening loop — extend the allow
  list in `autopilot/settings/autopilot.json` once you've seen what was
  denied, rather than pre-approving broadly up front. `ship-work` can also
  retry a flaky CI job once, per its own retry budget, now that `gh run *`
  (`list`/`view`/`rerun`/`watch`) is on the allow list — no more stopping to
  ask a human to re-run a hung Actions job by hand.
- **A claim looks stuck** (ticket stuck at `piv-drafting`/`piv-implementing`):
  the stale-claim sweep flags anything with no ledger entry in 3 hours and no
  held lock as `failed`, with a `history` entry. This covers both a
  workspace restart mid-run and a legitimate crash.
- **A failure was caused by something outside the plan/code** (a
  rate/usage/session limit trip, or the provider itself erroring —
  `overloaded`, `529`, `API Error`): the orchestrator does not dead-end this
  at `failed`. It restores the state the failed phase started from
  (`design`/`redesign`/`investigate`/`re-investigate` → `queued`, `build`/
  `fix` → `piv-draft-review`, `review` → `piv-review-pending`) and records
  the matched signature in the ticket's `history`, so the next cycle picks
  the same work back up once things clear. The notify title says `requeued
  after external failure: <issue>` instead of `FAILED`. This still counts
  toward the two-consecutive-failure counter below — that backoff is what
  stops a re-queue from thrashing.
- **Two consecutive failures:** autopilot auto-pauses and pings; `rm
  ~/.autopilot/pause` or `ap resume` once you've fixed the cause. Exception:
  if the failing run's own stderr/stdout matched a usage/rate/session-limit
  signature (`usage limit`, `rate limit`, `429`, `quota`, or `session limit`,
  case-insensitive — the narrower slice of the external-cause signature
  above; a provider outage tagged `overloaded`/`529` still gets reason
  `failures` and waits for a human, since it doesn't clear on a fixed
  cooldown) the pause is tagged reason `usage-limit` and clears **itself**
  once it's older than `AP_LIMIT_COOLDOWN_MIN` (default `60`) minutes — a
  real bug (reason `failures`) or a pause you set by hand (`ap pause`,
  reason `manual`) never auto-clears. `ap status` shows the reason and, for
  a usage-limit pause, when it will auto-resume.
- **No cycles for a while:** `ap status` and the daily brief both surface a
  ledger gap over an hour as a warning — check the tmux session
  (`tmux attach -t autopilot`) and `~/.autopilot/logs/cycle.log`.

## A note on `coder-packages/claude/skills/`

This repo's `claude/skills/` is the single source of truth for
`implement-issue`, `ship-work`, `daily-brief`, `test-issue`,
`autopilot-protocol.md`, `headless-protocol.md`, and the `piv-*` bug-path
family (`piv-investigate-issue`, `piv-implement-issue`, `piv-commit`,
`piv-create-pr`, `piv-review-pr`, `piv-validate`, `piv-plan-implementation`,
`piv-implement`, `worktree-create`) plus the adversarial-review and
delegation skills it depends on (`babysit-pr`, `debate-review`, `red-team`,
`challenge`, `codex-delegate`) (plus the retired `plan-issue`/`implement-plan`
stubs, kept symlinked so a stale invocation fails informatively rather than
404ing). The JourneyAI checkout (`AP_WORK_REPO`) never holds
its own copies — `scripts/install-autopilot.sh` symlinks each
`.claude/skills/<name>` entry there straight into this repo, `skip-worktree`s
any path the team repo still tracks underneath so the substitution never
shows up in that repo's `git status` or gets committed, and hides the
(untracked) symlink names via that repo's `.git/info/exclude`. Re-running the
installer re-converges all of this; it's idempotent.

**Recovery:** if a `git pull` in the JourneyAI checkout ever conflicts on a
skip-worktree'd path, run `git update-index --no-skip-worktree <file> && git
checkout -- <file>` there, then re-run `./scripts/install-autopilot.sh` from
this repo to re-symlink and re-skip-worktree it.

## Why `supercronic -overlapping`

`ap up` starts supercronic with `-overlapping`. This is required, not a
preference: a cycle stays alive for the whole act it dispatched (tens of
minutes for a build/fix, though review is mostly bot-round wait), and
without the flag supercronic skips every tick while the previous one runs —
which serializes the pipeline and leaves free lanes idle no matter how many
issues are waiting. Overlap is safe because `ap-cycle.sh` owns its own
mutual exclusion: `lock.poll` allows one decider at a time, `lock.plan.1` ..
`lock.plan.N` (`AP_PLAN_SLOTS`) cap the plan lane at N concurrent
design/investigate occupants, `lock.build.1` .. `lock.build.N`
(`AP_BUILD_SLOTS`) cap the build lane at N concurrent build/fix occupants,
`lock.review.1` .. `lock.review.N` (`AP_REVIEW_SLOTS`) cap the review lane
at N concurrent occupants, `lock.ship.1` .. `lock.ship.N` (`AP_SHIP_SLOTS`)
cap the (now dead — see "Retired: the legacy plan/implement/ship chain"
above) ship lane at N concurrent standalone ship retries, though none can be
dispatched any more, and a cycle with nothing to do exits in seconds.
</content>
