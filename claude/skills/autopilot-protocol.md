# Autopilot headless protocol — feature-path addendum

This document is the **feature-path (plan/build/ship) addendum** to
`.claude/skills/headless-protocol.md` — **read that first**. It defines the
trigger, the `dontAsk` discipline, the status vocabulary, parking,
`status.json`, the queue contract, the ask→fallback rule, the Linear
footprint, and the background-work rule, all shared across every pipeline.
This document states only what is specific to the legacy feature path: its
own state set and the orchestrator guarantees `ap-cycle.sh` makes to it.
(`/plan-issue` and `/implement-plan` are retired, folded into
`/implement-issue`'s two phases — this document still uses "the plan phase"
and "the implement phase" as the natural names for what each used to be.)

Launch mechanism is a wrapper-side, not skill-side, concern (see
`headless-protocol.md`'s "## Parking"): `ap-cycle.sh` launches a headless act
as either a one-shot `claude -p` (`AP_ACT_LAUNCH_MODE=oneshot`) or a
persistent interactive session in its own tmux window
(`AP_ACT_LAUNCH_MODE=persistent`, the default). Nothing in this document or
in a skill's own headless section depends on which — a skill never needs to
know or care.

## Local queue contract — this pipeline's states

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
Everything else about how `queued`/`plan-review`/`needs-input`/`ship-pending`
tickets get claimed, approved, replied to, and retried is the generic
mechanism documented once in `headless-protocol.md`'s "## Local queue
contract" — nothing about it is feature-path-specific.

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
