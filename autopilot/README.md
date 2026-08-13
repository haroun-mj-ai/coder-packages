# Autopilot

A 24/7 scheduler that runs the three-skill delivery chain (`/plan-issue` →
`/implement-plan` → `/ship-work`) headlessly on this Coder workspace, so that
Haroun's own touchpoints shrink to: label an issue, review the plan privately
from his phone, test the result, and merge. It never merges anything itself —
that gate stays human, every cycle, forever.

## Install

```bash
cd coder-packages
./scripts/install-autopilot.sh          # idempotent, safe to re-run
./scripts/install-autopilot.sh --check  # report convergence, change nothing
```

This installs `tmux` and `supercronic` if missing, creates
`~/.autopilot/{runs,briefs,logs}`, seeds `~/.autopilot/env` (only if absent —
never overwritten), symlinks `autopilot/bin/*` into `~/.local/bin`, adds a
managed self-heal block to `~/.bashrc` that runs `ap up --quiet` on every
interactive login, and wires the skills this feature runs (`plan-issue`,
`implement-plan`, `ship-work`, `autopilot-poll`, `daily-brief`,
`autopilot-protocol.md`) as symlinks into the JourneyAI checkout
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
- `AP_INBOX_REPO` (default `haroun-mj-ai/autopilot-inbox`) — the private
  GitHub repo used for plan review, and the only intake channel autopilot
  scans.
- `AP_FULL_POLL_INTERVAL_MIN` (default `360`, i.e. 6h) — minutes between the
  pre-scan gate's fallback full poll. Intake is fully deterministic via the
  two inbox legs above, so this is pure insurance against (a) a human
  comment misclassified as agent-authored by the `Plan file:` / `Phase:`
  marker heuristic, and (b) a claim stranded by a mid-cycle crash that the
  poll skill's own stale-claim sweep would recover — not a queue-pickup
  mechanism. Set to `0` to disable this leg entirely.
- `AP_BUILD_SLOTS` (default `2`, clamped to `1`-`4`) — concurrent
  implement→ship chains. Safe here specifically because backend tests run on
  mongomock (in-memory, per-test, never shared) and every build works in its
  own git worktree. See "Concurrent builds" below.
- `AP_SHIP_SLOTS` (default `3`, clamped to `1`-`6`) — concurrent *standalone*
  ship-only retries (its own lane, separate from `AP_BUILD_SLOTS`). Capped
  higher than the build lane deliberately: a ship act is almost pure waiting
  on GitHub CI — it starts no dev servers and barely touches the machine — so
  many can be in flight with negligible added load. Does not affect the ship
  half of an implement→ship chain, which stays on its build slot. See
  "Concurrent builds" below.
- `AP_LIMIT_COOLDOWN_MIN` (default `60`) — minutes a usage-limit auto-pause
  (see "Two consecutive failures" below) waits before clearing itself. `0`
  disables auto-resume entirely, so every pause then waits for a human,
  same as before this existed.
- `AP_POLL_MODE` (default `model`) — `model` runs the haiku `/autopilot-poll`
  skill every cycle; `deterministic` runs `ap-decide.sh` instead, for $0. See
  "Poll modes" below before flipping this.

At least one of `NTFY_TOPIC` / `SLACK_WEBHOOK_URL` must be set for pings to
actually go anywhere; unconfigured, `ap-notify.sh` just logs to
`~/.autopilot/logs/notify.log`.

## Daily flow

1. **Label** a Linear issue `agent:queue`. Autopilot claims it (assignee +
   `In Progress`) and plans it on the next cycle.
2. **Review privately.** The full plan markdown is posted as an issue in the
   private inbox repo (`AP_INBOX_REPO`) — readable from the GitHub mobile app,
   invisible to the rest of the team. A phone ping links you there.
3. **Approve or give feedback**, as a comment on that inbox issue:
   - Comment `go` (exact word, case-insensitive) to approve — the very next
     cycle claims it and starts building.
   - Comment anything else and it is treated as feedback: the next cycle
     re-plans in place, quoting your comment.
4. **Build happens unattended**, on one of `AP_BUILD_SLOTS` (default `2`)
   concurrent build slots, each with its own frontend/backend port pair
   (`5173+n`/`8000+n` for slot `n`; the human's own `5173`/`8000` are never
   assigned to a slot) — see "Concurrent builds" below. `implement-plan` runs
   full QA (including the four-server comparison), then tears down the
   changed-pair servers and leaves only your baseline (5173/8000) bound. The
   inbox label swaps `building` → `shipping` the moment `ship-work` starts
   (with its own ping), so you can tell "still building" apart from "opening
   the PR" — then `ship-work` opens a PR with `--no-merge`. You get a "ready
   to test" ping with the PR link and the exact relaunch commands (worktree
   paths, ports) — also posted on the inbox issue. Headless autopilot never
   comments on Linear: the claim and the `agent:ready-to-test` label are its
   only Linear writes; everything else (PR links, QA notes, relaunch
   commands) lands in the private inbox issue.
5. **Morning:** run the relaunch commands from the inbox issue, test against
   the running servers, then run the interactive `/ship-work` yourself to
   merge (autonomous merging is permanently out of scope) — it also archives
   the plan under `docs/plans/completed/`.

A daily brief (`ap-brief.sh`, 07:00 `AP_TZ` by default) pings a digest of
what's awaiting approval, ready to test, needs input, or failed, plus cost vs
budget and any scheduler gap.

### The 1-minute pre-scan gate

`ap-cycle.sh` fires every minute, but the haiku poll (`/autopilot-poll`) —
the only step that spends tokens before there's something to act on — only
runs when a zero-token bash `gh` scan finds a plausible reason to wake it.
The private inbox repo (`AP_INBOX_REPO`) is the only intake channel (no
Linear polling): intake happens by opening a new inbox issue titled with the
Linear id (e.g. `ENG-1234`) from the GitHub mobile app to delegate work, or
by commenting on an existing `plan-review` / `needs-input` inbox issue.
Concretely, the gate wakes the poll when it finds: an open inbox issue with
none of the eight state labels (`planning`/`plan-review`/`building`/
`shipping`/`ready-to-test`/`needs-input`/`failed`/`ship-pending`) — a fresh
delegation; an unseen human comment (not one of autopilot's own `Plan file:`
/ `Phase:`-stamped posts) on a `plan-review` or `needs-input` inbox issue; an
open inbox issue labeled `ship-pending` (implement finished and committed,
ship still owed — see "Ship-only retry" below); or — as pure insurance
against a misclassified comment or a crash-stranded claim, not a
queue-pickup mechanism — more than `AP_FULL_POLL_INTERVAL_MIN` minutes
(default `360`, i.e. 6h; `0` disables this leg entirely) since the last
poll. The gate is deliberately biased toward waking: a wrong "maybe" costs
one idle haiku poll, which is what the old `*/20` cadence spent on every
single fire.

### Ship-only retry

Sometimes `implement` succeeds — the code is committed — and only the ship
phase fails (an external cause such as a session/rate limit trip, or a hard
CI stop). Re-running the whole `implement → ship` chain would be wasteful and
risk re-doing already-good work, so the pipeline retries just the ship: the
inbox label `ship-pending` means "implement committed, ship still owed" —
set by the orchestrator when a ship phase fails for an external cause (see
"Two consecutive failures" below), or reachable by relabelling an issue by
hand. The next cycle claims it (`ship-pending` → `shipping`) and dispatches
`/ship-work --headless --no-merge` directly, with no plan or implement step
first. It claims its own **ship lane** slot (`AP_SHIP_SLOTS`, default `3`) —
deliberately *not* a build slot: a standalone ship is almost pure CI-wait, so
it must never queue behind a busy build lane. This is distinct from the ship
half of an implement→ship chain, which stays on the build slot it already
holds for the whole chain. See "Concurrent builds" below.

## Concurrent builds (and ships)

Three lanes, each its own mutual-exclusion mechanism under `~/.autopilot`:

| lane  | slots                          | default cap    | what runs there |
|-------|---------------------------------|----------------|------------------|
| plan  | `lock.plan` (single)             | 1              | `plan`/`replan` |
| build | `lock.build.1` .. `lock.build.N` | `AP_BUILD_SLOTS`, default `2`, clamped `1`-`4` | `implement`, plus the ship half of an implement→ship *chain* |
| ship  | `lock.ship.1` .. `lock.ship.N`   | `AP_SHIP_SLOTS`, default `3`, clamped `1`-`6` | a *standalone* ship-only retry (`action:ship` from a `ship-pending` issue) |

The build lane lets several implement→ship chains run at once — safe in this
repo specifically, not in general: backend tests run on mongomock
(in-memory, created fresh per test), so concurrent `pytest` runs never share
a database, and every build works in its own git worktree, so concurrent
implementers never touch the same checkout. Each build slot gets a dedicated
frontend/backend port pair, `5173+n`/`8000+n` for slot `n` (`n` starts at
`1`, so the human's own `5173`/`8000` baseline pair is never handed to a
slot).

The ship lane is capped *higher* than the build lane deliberately: a
standalone ship act is almost pure waiting on GitHub CI — it starts no dev
servers and barely touches the machine — so many can be in flight with
negligible added load, and it must never queue behind a full build lane (that
was the bug this lane exists to fix). Each ship slot gets its own port pair
too, `5180+n`/`8010+n` for slot `n`, deliberately non-overlapping with both
the build base and the human's baseline — `ship-work` serves no UI, so these
ports exist only to keep its local gates from colliding with a concurrently
running build; the frontend CORS allowlist is irrelevant here for the same
reason. This does **not** apply to the ship half of an implement→ship
*chain* run in the same cycle: that chain keeps the build slot (and its
build-lane ports) it already holds for both halves — it never touches the
ship lane at all.

Every lane is reported busy to the poll only when every slot in it is full
(lowest-numbered free slot wins, per lane); the orchestrator tells the
headless session its assigned ports as literal prompt text, `--ports
fe=<port>,be=<port>`, the same mechanism as `--run-dir`.

## Controls

```bash
ap up        # start the tmux session running supercronic (idempotent)
ap down      # stop it
ap status    # tmux liveness, pause state (+ reason), build/ship slot
             # occupancy and plan lane state, last 3 ledger lines, gap warning
ap pause     # writes ~/.autopilot/pause (reason "manual", never auto-clears)
ap resume    # rm the pause file, reset the consecutive-failure counter
```

The pause file (`~/.autopilot/pause`) is the one-command override for
anything invasive you're about to do by hand — it does not touch an act
already in flight (the flock is per-slot), but no new cycle starts while it
exists. Autopilot also auto-pauses itself (with a ping) after 2 consecutive
`FAILED` cycles. `ap down` refuses (unless `--force`d) while any build slot,
any ship slot, or the plan lane is occupied, for the same "would kill an act
in flight" reason.

Budgets are the other brake: `AP_MAX_ISSUES_PER_DAY` and
`AP_MAX_DAY_COST_USD` in `~/.autopilot/env`, checked against the day's ledger
before every acting cycle.

## Poll modes

Every cycle's poll step decides the single next action for that cycle
(triage of the private inbox) and, if there is one, claims it (a label
swap). `AP_POLL_MODE` in `~/.autopilot/env` picks how that decision gets
made:

- **`model`** (default) — invokes the `/autopilot-poll` skill on a haiku
  `claude -p` call, same as always. This is judgement-shaped prose: it reads
  the inbox, reasons about which tier applies, and emits a JSON decision.
  Costs real money every cycle it runs (~$0.13/poll observed), even on the
  ~25% of polls that decide nothing.
- **`deterministic`** — calls `autopilot/bin/ap-decide.sh --claim` instead.
  Every step the poll makes is mechanical — a label query, a first-line
  marker check (`Plan file:`/`Phase:`/`Autopilot:`), an exact-word match
  (`go`/`auto`), a regex (`ENG-\d+`), a priority ordering, or a label swap —
  so `ap-decide.sh` implements the exact same tiers as
  `claude/skills/autopilot-poll/SKILL.md` in bash + Python against live
  `gh` data, for $0. It also makes the claim (the label swap) enforced
  rather than advisory: the model poll's claim is prose that can lag or be
  skipped, which is how two implementers raced on the same worktree for
  ENG-1308 (two consecutive polls both emitted `implement` for it).

Compare the two before flipping the switch:

```bash
ap decide     # runs ap-decide.sh --dry-run against the REAL inbox, no
              # writes, and pretty-prints the decision plus a one-line
              # reason per tier it evaluated
```

Run `ap decide` for a while side by side with the live `model`-mode pipeline
and confirm it would have made the same call on the same inbox state before
setting `AP_POLL_MODE=deterministic` in `~/.autopilot/env`. The two
implementations are kept in step deliberately (`autopilot-poll/SKILL.md`
says so at its top) — if you change one tier's rule, change the other.
`ap-decide.sh` never touches Linear (no credential available to it — the
Linear claim on tier 5's new-delegation path now happens inside
`/plan-issue --headless` itself, at the start of its run, whichever poll
mode chose it).

## Troubleshooting

- **Permission denials under `dontAsk`:** an acting run fails fast (`FAILED`),
  and the denial string lands both in the inbox issue's comment and in the
  day's ledger line. This is the expected tightening loop — extend the allow
  list in `autopilot/settings/autopilot.json` once you've seen what was
  denied, rather than pre-approving broadly up front. `ship-work` can also
  retry a flaky CI job once, per its own retry budget, now that `gh run *`
  (`list`/`view`/`rerun`/`watch`) is on the allow list — no more stopping to
  ask a human to re-run a hung Actions job by hand.
- **A claim looks stuck** (inbox issue stuck at `planning`/`building`): the
  stale-claim sweep flags anything with no ledger entry in 3 hours and no
  held lock as `failed`, with a comment. This covers both a workspace restart
  mid-run and a legitimate crash.
- **A failure was caused by something outside the plan/code** (a
  rate/usage/session limit trip, or the provider itself erroring —
  `overloaded`, `529`, `API Error`): the orchestrator does not dead-end this
  at `failed`. It restores the state the failed phase started from
  (`plan`/`replan` → `Queued`, `implement` → `plan-review`, `ship` →
  `ship-pending`) and comments on the inbox issue naming the matched
  signature, so the next cycle picks the same work back up once things
  clear. The notify title says `requeued after external failure: <issue>`
  instead of `FAILED`. This still counts toward the two-consecutive-failure
  counter below — that backoff is what stops a re-queue from thrashing.
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

This repo's `claude/skills/` is the single source of truth for `plan-issue`,
`implement-plan`, `ship-work`, `autopilot-poll`, `daily-brief`, and
`autopilot-protocol.md`. The JourneyAI checkout (`AP_WORK_REPO`) never holds
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
minutes for a build, though a standalone ship is much cheaper — mostly
CI-wait), and without the flag supercronic skips every tick while the
previous one runs — which serializes the pipeline and leaves free lanes idle
no matter how many issues are waiting. Overlap is safe because `ap-cycle.sh`
owns its own mutual exclusion: `lock.poll` allows one decider at a time,
`lock.plan` caps the plan lane at one occupant, `lock.build.1` ..
`lock.build.N` (`AP_BUILD_SLOTS`) cap the build lane at N concurrent
occupants, `lock.ship.1` .. `lock.ship.N` (`AP_SHIP_SLOTS`) cap the ship lane
at N concurrent standalone ship retries, and a cycle with nothing to do exits
in seconds.
