# Feature: `ap` bug-path pipeline — route `--kind bug` tickets through the `piv-*` skill family

The following plan should be complete, but its important that you validate documentation and codebase patterns and task sanity before you start implementing.

Pay special attention to naming of existing utils types and models. Import from the right files etc.

## Feature Description

`ap` (the personal 24/7 headless autopilot in `/home/coder/coder-packages`) today knows exactly one delivery chain: `/implement-issue --phase plan` → `/implement-issue --phase implement` → `/ship-work`, expressed as three lanes (plan/build/ship), five queue states (`planning`/`plan-review`/`building`/`shipping`/`ship-pending`), and five decider tiers. Every ticket, feature or bug, runs through it.

This feature adds a **second, parallel fork** for tickets classified as bugs at intake time, built out of the `piv-*` skill family that already exists (and is already symlinked into the work repo) but has never been driven headlessly:

`piv-investigate-issue` (RCA + a conditional `/red-team` or `/challenge` gate) → **human RCA review gate** → `piv-implement-issue` + `piv-commit` + `piv-create-pr` (one act) → `piv-review-pr` (which dispatches `debate-review`, then hands to `babysit-pr` for round-based bot-review triage).

The fork is selected by a new `kind` field on the queue ticket, set by a new `ap queue --kind feature|bug` flag (default `feature`). It gets its own disjoint state set (`piv-drafting`/`piv-draft-review`/`piv-implementing`/`piv-review-pending`/`piv-reviewing`), its own new orchestrator lane for the review phase (`AP_REVIEW_SLOTS`, `lock.review.N`, ports `5187+n`/`8020+n`), and its own decider claims — while reusing the plan lane for investigation and the build lane for the fix.

It also does the documentation refactor this requires: the phase-agnostic half of `claude/skills/autopilot-protocol.md` moves into a new `claude/skills/headless-protocol.md`, so five new skills can point at one shared contract instead of each re-stating `status.json`, the ask→fallback rule, and the `dontAsk` command discipline.

The pipeline's central invariant is preserved exactly: **nothing merges.** `piv-review-pr`/`babysit-pr` are structurally incapable of it (`piv-review-pr/SKILL.md:17-19`, `babysit-pr/SKILL.md:305-306`), which is the property that lets this fork join `ap` without weakening its one hard rule.

## User Story

As the sole operator of a 24/7 headless autopilot pipeline
I want bug-classified tickets to run through the `piv-*` diagnosis-first chain (RCA → adversarial gate → fix → PR → agentic review) instead of the feature-shaped plan/implement/ship chain
So that a bug gets a reviewable root-cause artifact and a bot-review round worked to resolution before it reaches me, and I still make every merge decision myself.

## Problem Statement

1. **Bugs run through a feature-shaped pipeline.** `/implement-issue --phase plan` produces an implementation plan; a bug needs a root-cause analysis with an evidence chain. The plan phase's own risk classifier, acceptance-scenario drafting, and Codex second-draft are calibrated to "build a thing", not "find why a thing broke". The artifact a human reviews at the gate is therefore the wrong artifact.
2. **No adversarial gate on a proposed fix.** `implement-issue` has one (`SKILL.md:354-399`, conditional `/red-team` when the plan touches a guard) — a genuinely valuable step, evidenced by the ENG-1406 case recorded in it. Nothing on the bug side has it, even though a bug fix that relaxes a guard is the single highest-risk change class the pipeline handles.
3. **No agentic review round before the human.** Today `ship-work` confirms the branch is rebased and locally gate-clean, then stops. Bot review findings (Codex, Greptile, debate-review) accumulate unworked until the human sits down. `piv-review-pr` + `babysit-pr` exist to work those rounds and were built for exactly this, but have never been wired in.
4. **The `piv-*` skills have no headless mode at all.** None of the five has a `## Headless mode` section, so under `claude -p`/`dontAsk` they hit ask-points with no documented default, no `status.json` write, and no queue write — the wrapper would reconcile every one of them as a crash.
5. **The headless contract is coupled to the old phase names.** `autopilot-protocol.md`'s "States" section (`:195-225`, corrected by the plan-critic audit — an earlier draft cited `:196-225`) hard-codes `planning`/`plan-review`/`building`/`shipping`/`ship-pending`, and its `status.json` shape (`:112-133`) hard-codes `"phase": "plan|implement|ship"`. A second pipeline cannot point at it as-is, and duplicating the mechanics into five new skills is exactly the drift-generator this repo has spent effort eliminating (`ap_queue.py:12-15` on why queue read/write is the one shared-not-duplicated piece).

## Solution Statement

Add the bug fork as a **structurally disjoint second path through the same machinery**, so the legacy path is provably untouched:

- **One classification point.** `kind: "feature"|"bug"` on the ticket, set at `ap queue` time, defaulting to `feature`. Missing on an existing ticket file reads as `feature` (back-compat by omission).
- **Shared, kind-agnostic states, disjoint from the legacy set.** `piv-drafting`/`piv-draft-review`/`piv-implementing`/`piv-review-pending`/`piv-reviewing` are **shared by both kinds** (a later feature fork reuses this exact set rather than earning a third parallel one — see `docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md`) **and disjoint from the legacy five**. Consequence: **the decider reads `kind` in exactly two places** — the `queued` intake tier and the `piv-draft-review` tier, the only two states where both kinds sit and the next action differs. Every other tier is determined by state alone (tier 4, the stale sweep) or by *phase* alone (tier 3 — `investigate`/`fix` are bug-only phase names, and a feature fork's phase names are disjoint from them too, so `phase_at_question` already encodes the kind without a `kind` read). Those two coupling points are what keep coexistence auditable.
- **Naming rationale for the five state names, in priority order.** **(1) Kind-agnostic without being abstract.** A plan and an RCA are both *drafts pending a human's approval* — that is literally true of each, and it is what the state means. `piv-designing`/`piv-design-review` was considered and rejected: "design review" is wrong for a bug (you review a diagnosis, not a design), and the whole point of a shared name is one word that fits both. `piv-drafting`/`piv-draft-review` also morphologically mirrors the legacy pair `planning`/`plan-review`, so the mapping is obvious to anyone who knows the old machine. **(2) No new state name contains a legacy state name as a substring.** This is a hard rule for the whole set, not a coincidence: `grep 'building'` must not match a piv state, because this document's own VALIDATE lines and this repo's audit habit are grep-based. It is specifically why the third state is **`piv-implementing`, not `piv-building`** — `piv-building` contains `building`. Every candidate name was checked against `{queued, planning, plan-review, needs-input, building, shipping, ship-pending, ready-to-test, failed, done}` before being accepted. **(3) The `piv-` prefix makes the fork visible at a glance** in `ap sessions`, `ap runs`, `daily-brief` and every `history` event, and guarantees disjointness from the legacy five by construction rather than by inspection.
- **Three acts per bug, mirroring the three lanes.** `investigate` on the plan lane (judgment-heavy, no servers, produces a reviewable committed artifact — the exact shape of the plan phase); `fix` on the build lane with its port pair (runs the real suite, may start the worktree servers for a reproduction check); `review` on a new review lane. `piv-commit` and `piv-create-pr` have zero human-judgment ask points, so they ride inside the `fix` act rather than earning states of their own.
- **No chain.** Unlike implement→ship (a chain that keeps its build slot for both halves, `ap-cycle.sh:471-482`), `fix` does **not** chain into `review` — it writes `piv-review-pending` and a later cycle claims it on the review lane. Review is 20-60 minutes of mostly waiting on bot rounds; chaining it would pin a build slot for that whole time. This also means `ap-resume.sh` needs **no** chained-dispatch branch for the bug path (its most complex code, `:431-468`), a real simplification.
- **The adversarial gate is a skill step, not a headless behavior.** `/red-team` (conditional on the fix touching a guard) and `/challenge` (conditional on the root-cause chain leaning on a metric rather than `file:line` evidence) become numbered step 7 of `piv-investigate-issue`, mirroring `implement-issue/SKILL.md:354-399` exactly — so they run interactively too, and the headless section only maps their verdicts (`do-not-ship`/`does-not-survive` → `NEEDS_HUMAN`).
- **Centralized headless contract.** New `claude/skills/headless-protocol.md` holds the phase-agnostic core (trigger, `dontAsk` command discipline, status vocabulary, parking, `status.json`, the queue contract's generic half, the ask→fallback rule, the Linear footprint, the never-background-at-turn-end rule, the single `$QUEUE_PY` resolution snippet). `autopilot-protocol.md` shrinks to the feature-path addendum. Each new skill gets a one-sentence pointer plus a skill-specific ask-point→fallback table — nothing else.

## Out of Scope / Non-Goals

- **Not included: the feature fork.** `--kind feature` tickets keep running today's `/implement-issue`/`/ship-work` dispatch, unchanged, coexisting. Rewiring the feature path onto `piv-plan-implementation` → `piv-implement` is an explicit follow-up plan.
- **Not included: removing the legacy path.** "Full replace" is the agreed end state, reached in three steps: this plan (bug fork), the follow-up (feature fork), then a **third, later** plan that deletes `implement-issue`/`ship-work` dispatch once both forks are proven in production. This plan deliberately adds a second path rather than replacing the first. *(This is a reinterpretation of "full replace" as incremental — see OPEN QUESTIONS, it wants explicit confirmation, not a silent decision.)*
- **Not changing: any legacy state, tier, lane, lock, port range, or dispatch prompt.** Every edit to `ap-decide.py`/`ap-cycle.sh` is additive; the five legacy states gain no new transitions. The one exception, called out honestly: **two legacy skills' headless sections get one edited sentence each** (`implement-issue/SKILL.md:1139-1149`, `ship-work/SKILL.md:394-396`) so their pointers name the new core doc, plus deletion of `implement-issue`'s duplicated `$QUEUE_PY` snippet and both skills' duplicated background-work rule. No behavior change; it is the de-duplication the feature brief explicitly asked for.
- **Not included: autonomous merging.** Permanently out of scope for this pipeline. `babysit-pr`'s "ask the user whether to merge" terminal becomes `ready-to-test` + `status: DONE`, never a merge call.
- **Not included: a second new lane for investigation.** Investigation reuses the plan lane. Only one new lane (review) is added.
- **Not included: the four-server baseline browser comparison** that `implement-issue`'s Phase B mandates. A bug fix's evidence is its reproduction case plus its regression test; the changed-vs-baseline UI comparison is a feature-diff tool. (Assumption — see OPEN QUESTIONS.)
- **Not included: `piv-fix-review-findings`, `piv-review-changes`, `piv-validate`, `piv-plan-implementation`, `piv-implement`, `piv-slice-epic`** getting headless sections. Only the five bug-path skills plus `red-team`/`challenge`.
- **Not included: fixing `resolve_plan_path`'s substring hazard** (`ap-decide.py:47-49`: `*eng-123*` also matches `eng-1234-foo.md`). Flagged in NOTES; the new RCA resolver deliberately does not replicate it.

## Feature Metadata

**Feature Type**: Enhancement / Refactor (bug-fix-adjacent tooling change)
**Estimated Complexity**: **High**
**Primary Systems Affected**: `autopilot/bin/` orchestrator (queue schema, decider, lanes, dispatch, reconcile, resume, CLI, dashboard), `claude/skills/` headless contract + 7 skill files, `autopilot/settings/autopilot.json` permission profile, `scripts/install-autopilot.sh` skill wiring, `autopilot/tests/` harnesses
**Dependencies**: no new libraries. Existing external tools the bug path newly depends on at runtime: `gh` (authenticated), `jq` (required by `babysit-pr/scripts/threads.sh`), `node` (required by `debate-review/scripts/review-pr.mjs` and `codex-delegate/scripts/relay.mjs`), `kata` (best-effort). All four resolve on this workspace today (`/home/coder/.nix-profile/bin/{jq,node}`, `/home/coder/.local/bin/kata`).

**Why High, not Medium:** the change is not large in lines but it is wide in *invariant surface*. It adds 5 states to a state machine with 4 independent readers (`ap_queue.STATES`, `ap-decide.py`'s tiers *and* its stale sweep, three separate state tuples in `ap-runs.py`, `daily-brief`'s enumerated sections), a lane to a concurrency scheme with 8 independent readers (probe, lock path, port assignment, window name, two different window-name regexes in two files, `ap down`'s refusal, `ap status`'s slot line, `ap-resume.sh`'s re-acquisition), and 3 phases to a reconcile path with per-phase requeue mapping duplicated across two files by this repo's stated duplicate-small-helpers convention. Miss any single reader and the failure is silent and late: a ticket no tier claims, a crashed act no sweep sweeps, a lane `ap down` kills without warning. What keeps it from Very High: the disjoint-state-set design collapses most conditionals to a state lookup, and the repo has a genuinely good existing test harness (1653-line `test_cycle.sh` stubbing `claude`/`tmux`, 453-line `test_decide.sh` on real queue fixtures) that the new cases slot straight into. **Sizing note for whoever implements this** (plan-critic audit observation, not a plan change): the `test_cycle.sh` task (12+ new cases plus stub changes, in an already-1653-line file with real `flock` waits) and the `ap-runs.py` task (8 separate edit sites in a 1733-line file) are the two units most likely to need splitting into sub-passes during actual implementation.

## Related Work

**Implements**: no ticket (free-form, personal-tool repo) · **Epic**: none

**Back-references** (plans this builds on or inherits decisions from):

- `docs/plans/2026-08-11-autopilot-pipeline.md` — Why: the plan that built `ap` itself. Inherit its settled calls verbatim and do not reopen them: never merge autonomously; plan review is private (local queue, never Linear); `flock`-based mutual exclusion; per-rolling-day budgets; skills read from `coder-packages/claude/skills/` as the single source of truth. Its "Out of scope" and "Design review" sections are the standing constraints this plan operates inside.

**Forward-references** (plans that extend or supersede this — append as follow-ups get created):

- (none yet) — expected: (a) the feature fork (`piv-plan-implementation` → `piv-implement`), (b) the legacy-path removal once both forks are proven.

---

## CONTEXT REFERENCES

### Relevant Codebase Files IMPORTANT: YOU MUST READ THESE FILES BEFORE IMPLEMENTING!

**Orchestrator core**

- `autopilot/bin/ap_queue.py` (lines 26-29, 93-108, 116-136, 178-191, 229-301) - Why: the ONE shared queue implementation. `STATES` set, `list_queue`'s ordering contract, `new_ticket`'s full schema, `transition`'s read-merge-write, and the CLI the bash callers use. Its header comment (`:7-15`) states the "deliberately the one shared-not-duplicated piece" convention — respect it.
- `autopilot/bin/ap-decide.py` (lines 38-55, 86-100, 120-131, 136-301) - Why: every tier to extend. `resolve_plan_path` is the pattern the new RCA resolver mirrors; `sweep_stale`'s state tuple MUST gain the new states; `_issue_lock_free`'s docstring explains the mid-shutdown race the new `piv-draft-review` tier inherits verbatim.
- `autopilot/bin/ap-cycle.sh` (lines 227-273, 447-553, 572-603, 803-850, 856-1030) - Why: lane probing, the action→lane/slot/port case statement, `act_model`, `window_name_for`, the dispatch prompts, and the full reconcile (FAILED external-signature requeue at `:915-928`, NEEDS_HUMAN parking at `:984-1001`, DONE at `:1003-1029`).
- `autopilot/bin/ap-env.sh` (lines 66-92, 94-135) - Why: `AP_BUILD_SLOTS`/`AP_SHIP_SLOTS` clamp idiom to copy exactly for `AP_REVIEW_SLOTS`; `plan_lock_file`'s "defined in the one file all four entrypoints source" rationale.
- `autopilot/bin/ap-resume.sh` (lines 175-211, 213-240, 298-344, 421-495) - Why: parked-act resume. Its lane→slot re-acquisition `case "$lane"` (`:302-327`) needs a `review` arm; its DONE branch (`:421-470`) needs the bug phases. Its header (`:25-31`) documents what it deliberately does NOT replicate.
- `autopilot/bin/ap` (lines 19, 189-215, 228-262, 306-329, 341-347, 613-661) - Why: usage text, `lane_free`, `ap down`'s per-slot refusal, `lane_slot_line`, the `act_(build|ship)_N_...` window regex, and `cmd_limits`'s exact `--*-slots` convention.
- `autopilot/bin/ap-runs.py` (lines 74-82, 427, 518-555, 833, 891-901, 980-996, 1063, 1378-1383, 1424-1436, 1704-1708) - Why: **not in the brief's file list but load-bearing**. `_ACT_WINDOW_RE` (no underscores allowed in a phase name), `QUEUE_DASHBOARD_STATES`, `_queue_note`, `TERMINAL_STATES`, `PENDING_STATES`, `REQUEUE_STATE` (what `ap retry` does), and `cmd_queue` — **`ap queue` runs through here, not through `ap_queue.py`'s CLI** — so `--kind` must be added in both.

**Headless contract**

- `claude/skills/autopilot-protocol.md` (whole file, 351 lines; especially 19-31, 34-46, 48-58, 60-110, 112-154, 156-281, 283-300, 302-320, 322-351) - Why: the file being split. Sections 19-31/34-46/48-58/60-110/112-154/283-300/302-320 are phase-agnostic and move; 196-225 ("States") and 322-351 ("Orchestrator guarantees") are feature-path-coupled and stay.
- `claude/skills/implement-issue/SKILL.md` (lines 1137-1149, 1309-1318, 354-399) - Why: the pointer-sentence pattern to copy verbatim into five new sections; the duplicated `$QUEUE_PY` snippet to delete; the duplicated background rule to delete; and step 7b, the exact red-team conditional-dispatch template to mirror.
- `claude/skills/ship-work/SKILL.md` (lines 392-411, 413-432, 434-456, 462-468) - Why: the second instance of the pointer pattern; the hard-stops→NEEDS_HUMAN mapping shape; the success end-state write (state swap + `pr_urls` + Linear label) that `piv-review-pr`'s end state mirrors.

**Bug-path skills**

- `claude/skills/piv-investigate-issue/SKILL.md` (lines 33-41, 43-56, 98-104, 105-244, 246-261, 263-283) - Why: kata mirror, the parallel fan-out, the RCA output path, the full RCA template (gains one new section), the Linear-comment step (interactive-only headlessly), and the four edge cases to map.
- `claude/skills/piv-implement-issue/SKILL.md` (lines 28-35, 46-54, 56-66, 68-76, 124-154, 192-274) - Why: kata resume, the drift-check hard stop, the branch-selection block (**the block headless must override**), the Confidence:Low hard stop, the Codex adversarial test pass, and the output report (which needs a file path).
- `claude/skills/piv-commit/SKILL.md` (whole file, 33 lines) - Why: the entire procedure; needs the smallest possible headless section.
- `claude/skills/piv-create-pr/SKILL.md` (lines 12-18, 34-48, 63-90, 94-101) - Why: base detection, the Phase 1 precondition table, the `git push -u origin HEAD` call (passes today via the `Bash(git -C *)` allowance, but is still the wrong branch discipline on its own terms) and the `gh pr create` call (**genuinely blocked by the current permission profile — see GOTCHAs**), and the output block.
- `claude/skills/piv-review-pr/SKILL.md` (lines 21-32, 34-46, 48-67, 69-76) - Why: PR resolution + state guard, the validation phase, the `debate-review` dispatch (exit code 3 semantics), and the `babysit-pr` handoff.
- `claude/skills/babysit-pr/SKILL.md` (lines 42-106, 132-146, 222-238, 240-273, 282-308, 310-322) - Why: the harvest contract (and its hard `jq` dependency, declared at `:5`), autonomous blocker handling, the batched non-blocker ask (**the one real design call**), the repair budget, the merge gate, and the "stop and speak up" list.
- `claude/skills/red-team/SKILL.md` (lines 19-30, 33-46, 79-91, 142-155, 157-165) - Why: the behaviour-delta framing, the must-stay-fatal question, the replay step (**usually unobtainable headlessly**), the fresh-sub-agent rule, and the report shape whose Verdict this plan branches on.
- `claude/skills/challenge/SKILL.md` (lines 19-31, 34-57, 133-148, 150-162) - Why: the claim-pinning step, the instrument question, the fresh-sub-agent rule, and the `stands / stands with caveats / does not survive` verdict this plan branches on.

**Wiring, permissions, tests**

- `autopilot/settings/autopilot.json` (lines 4-60) - Why: the `dontAsk` allow list. **Multiple bug-path calls are currently denied** — enumerated in the GOTCHAs below.
- `scripts/install-autopilot.sh` (lines 270-338) - Why: `SKILL_NAMES` (`:281`) and `EXCLUDE_BODY` (`:328-334`). The `piv-*` symlinks exist in the work repo but are **not managed by the installer**, and `red-team`/`challenge` are not even excluded — verified: `git -C /home/coder/root-for-local status --porcelain .claude/skills` prints `?? .claude/skills/challenge` and `?? .claude/skills/red-team`.
- `autopilot/tests/test_cycle.sh` (lines 24-91, 98-183, 289-333, 1103-1185) - Why: the seed/assert helpers, the `claude` stub whose phase detection must learn the bug prompts, `setup_case`/`run_case`, and the build-slot cases whose shape the review-slot cases copy.
- `autopilot/tests/test_decide.sh` (lines 21-33, 43-61, 92-103, 105-110) - Why: the decider harness the new tier cases extend.
- `autopilot/README.md` (lines 49-59, 121-150, 201-237, 239-256, 320-338) - Why: the env-var docs, the decider/ship-only-retry sections, the concurrency table to extend, `ap down`'s documented refusal, and the skills-wiring note.

### New Files to Create

- `claude/skills/headless-protocol.md` - The phase-agnostic headless contract. Successor to `autopilot-protocol.md`'s generic half; the single doc all five new skill sections point at.
- `autopilot/tests/test_queue.sh` - Unit tests for `ap_queue.py`'s new `kind` field: default, validation, back-compat on a ticket file with no `kind` key, and `list_queue`'s multi-state form.

*(No new orchestrator files. Every plumbing change is additive inside existing files — deliberately: `ap-resume.sh`'s header comment records this repo's "duplicate small helpers rather than share them" convention, and adding a shared module would fight it.)*

### Relevant Documentation YOU SHOULD READ THESE BEFORE IMPLEMENTING!

No external documentation is required — this is an internal-only change to a personal tool with no new library or API. Phase 3 of the planning process was skipped on that basis.

Two internal cross-references matter and are already cited above rather than externally:

- `implement-issue/SKILL.md:354-399` — the live conditional red-team dispatch, including the ENG-1406 case that justifies it. This is the pattern, not a suggestion of one.
- `arXiv:2607.21656` as cited in `piv-review-pr/SKILL.md:11-19` and `piv-implement-issue/SKILL.md:124-129` — why Codex is used as challenger/adversary and never as sole reviewer of Claude-authored work. Preserve that direction in every new dispatch.

### Patterns to Follow

**Queue state writes (skill-side).** One `set` call per transition, carrying state + fields + a human-readable event, exactly as `implement-issue/SKILL.md:1205-1209` and `ship-work/SKILL.md:439-443`:

```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state <new-state> \
  --field key=value --event "description"
```

`$QUEUE_PY` is resolved **once per session**, from the new core doc's single copy of the snippet (`ap_queue.py` is not on `PATH`; `ap` is).

**Slot clamping (`ap-env.sh:66-92`).** Verbatim shape for `AP_REVIEW_SLOTS`: default via `${VAR:-n}`, then non-numeric → default, then `-lt min` → min, then `-gt max` → max, then a second `export`. A prose comment above it stating *why* this lane's cap differs from its neighbours' — every existing lane has one, and it is the only record of the reasoning.

**Lane probing (`ap-cycle.sh:241-266`).** Lowest-free-slot-first loop, `busy_<lane>=true` only when every slot is taken, appended to the comma-joined `busy_lanes` string handed to the decider.

**Decider tier (`ap-decide.py:245-269`).** Guard on lane-busy → `list_queue` (seq-ordered) → per-entry `_issue_lock_free` check → resolve the artifact path (or `needs-input` + `continue`, never `break`) → `transition(...)` claim write → build the decision dict → `break`. Plus a `trace(...)` line on **every** branch including the skips: `ap decide` renders these and they are the only debugging surface.

**Conditional adversarial dispatch (`implement-issue/SKILL.md:354-399`).** Bold **Conditional. Skip it and say so unless the trigger below fires**; an explicitly enumerated trigger list; a *why this exists and the cheaper check does not cover it* paragraph; a fresh `Agent` given the delta + current code/tests and **not** the argument for the change; a numbered "require back" list; and "record the trigger decision when it did not fire, so the skip is auditable."

**Headless section opener (identical in both existing skills).** One pointer sentence, then only what is skill-specific:

> Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own ask points map to.

**Ask-point mapping table.** Per-skill, three columns: ask point (with `SKILL.md:line`) | headless resolution (`documented default` / `NEEDS_HUMAN` / `FAILED` / `DONE-idempotent`) | what gets recorded. This table is the *whole* skill-specific payload; mechanics never repeat.

**Test case (`test_cycle.sh:387-397`).** A banner comment stating the case's intent, `setup_case`, `seed_ticket`, env knobs, `run_case`, then one `assert` per distinct claim with a `caseN: <claim>` description.

**Branch and push naming.** `haroun/eng-<id>-<slug>` — every existing worktree uses it (`git worktree list` confirms 8+), `piv-plan-implementation/SKILL.md:57` records it as `work.branch`, and the permission profile only allows `Bash(git push -u origin haroun/*)`. **Never** `fix/issue-<id>-<slug>` as `piv-implement-issue/SKILL.md:62` says interactively.

---

## IMPLEMENTATION PLAN

Phases run **top to bottom by default** — each assumes the phase above it is done. Where that is NOT the true dependency, it is annotated.

### Phase 1: The shared headless contract — new file, wired before anything reads it

Create `claude/skills/headless-protocol.md` as the phase-agnostic core, symlink it into the work repo, and add it to the installer's managed set — **before** Phase 2 removes anything from `autopilot-protocol.md`. Ordering is not cosmetic: acts are running 24/7, and an act that reads the shrunken `autopilot-protocol.md` must be able to follow its pointer to a file that already exists.

**Tasks:**

- Author the new doc: trigger, `dontAsk` command discipline, status vocabulary, parking, `status.json` (with a generalized `phase` and `artifact_path`), the queue contract's generic half, ask→fallback, Linear footprint, the never-background-at-turn-end rule, the single `$QUEUE_PY` snippet, and a new **Pipelines and their phase vocabularies** section tabulating both forks.
- Symlink into `$AP_WORK_REPO/.claude/skills/` and add to `install-autopilot.sh`'s `SKILL_NAMES` + `EXCLUDE_BODY`.

### Phase 2: Split `autopilot-protocol.md`, de-duplicate the two legacy skills

**Depends on:** Phase 1 (the pointer target must exist and be resolvable in the work repo first).

Reduce `autopilot-protocol.md` to the feature-path addendum; repoint `implement-issue` and `ship-work`; delete the two duplicated snippets the brief identified. **Run with `ap pause` held** — this is the one phase that edits documents a live act may read mid-turn.

### Phase 3: Ticket schema — `kind`, the new states, and `--kind` at intake

**Independent of:** Phases 1-2 (Python/CLI vs documentation; can proceed in parallel).

`ap_queue.py` gains `kind`, `KINDS`, `ticket_kind()`, the five new `STATES`, a multi-state `list_queue`, and `--kind` on its CLI. `ap-runs.py` gains `--kind` on `ap queue`, a kind prompt in the `[n]ew` dashboard popup, the new states in its three state tuples and `_queue_note`, and the new phases in `REQUEUE_STATE`.

### Phase 4: The review lane

**Independent of:** Phase 3 (concurrency plumbing vs schema; either order works).

`AP_REVIEW_SLOTS` + clamp + `lock.review.N` + ports `5187+n`/`8020+n` + the `review` window-name arm + both window regexes + `ap status`'s slot line + `ap down`'s refusal + `ap limits --review-slots` + the README concurrency table.

### Phase 5: Decider — new tiers, RCA resolution, stale sweep

**Depends on:** Phase 3 (states, `kind`, multi-state `list_queue`) and Phase 4 (the `review` token in `--busy`).

Merge the approve/feedback tiers to scan both forks seq-ordered; add `piv-review-pending` to tier 4 with a per-entry lane check; branch tier 5 on `kind`; extend tier 3's phase routing; add `resolve_rca_path`; add the three new states to `sweep_stale`.

### Phase 6: Orchestrator — dispatch, reconcile, resume

**Depends on:** Phases 4 and 5.

`ap-cycle.sh`'s action case statement, `act_model`, the three new dispatch prompts, the `piv-implementing → piv-review-pending` wrapper write, the requeue map, and the DONE notify branches. `ap-resume.sh`'s `review` lane arm and bug-phase DONE handling.

### Phase 7: Skill headless sections + the adversarial gate

**Depends on:** Phases 1-2 (the doc they point at). **Independent of:** Phases 3-6 — these are seven prose files with no code dependency on the plumbing, and can be authored in parallel with it. The *end-to-end run* obviously needs both.

`piv-investigate-issue` (new step 7 gate + new RCA section + headless section), `piv-implement-issue`, `piv-commit`, `piv-create-pr`, `piv-review-pr` (incl. the `babysit-pr` headless delegation rules), `red-team`, `challenge`.

### Phase 8: Permissions, installer wiring, brief

**Depends on:** Phase 7 (the exact tool calls the new sections make determine the allow list).

Extend `autopilot.json`'s allow list; add all bug-path skills to the installer's managed set; add the new states to `daily-brief`.

### Phase 9: Testing & validation

**Depends on:** all previous phases.

`test_queue.sh` (new), `test_decide.sh` + `test_cycle.sh` extensions (including the stub's phase detection), `test_install_skills.sh`, shellcheck/py_compile, then a supervised live bug end-to-end.

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable.

### Task Format Guidelines

Use information-dense keywords for clarity:

- **CREATE**: New files or components
- **UPDATE**: Modify existing files
- **ADD**: Insert new functionality into existing code
- **REMOVE**: Delete deprecated code
- **REFACTOR**: Restructure without changing behavior
- **MIRROR**: Copy pattern from elsewhere in codebase

---

### CREATE `claude/skills/headless-protocol.md`

- **IMPLEMENT**: The phase-agnostic headless contract. Move these sections out of `autopilot-protocol.md` **as-is except where noted**:
  - `## Trigger` (from `:19-31`) — unchanged.
  - `## Command discipline under dontAsk` (from `:33-46`, plan-critic-corrected offset) — one factual correction: the current text claims "`jq` is not even installed", which is false on this workspace (`/home/coder/.nix-profile/bin/jq`). Replace with: `jq` resolves via `~/.nix-profile/bin` for a shell that sourced the user's profile, but a cron-launched act's `PATH` inheritance is not guaranteed — so prefer `gh --jq` and `python3` over `jq`, and where a skill has a hard `jq` dependency it must preflight `command -v jq` and FAIL fast. The load-bearing rule (**a piped or compound Bash command is denied unless every segment is allowed; one command per Bash call**) is unchanged and stays emphatic.
  - `## Status vocabulary` (from `:48-58`) — unchanged.
  - `## Parking` (from `:60-110`) — unchanged, including the mandatory "stop dev servers **before** writing NEEDS_HUMAN" rule at `:98-102`.
  - `## status.json` (from `:112-154`) — two generalizations: `phase` becomes "the phase name this pipeline uses for this act (see Pipelines below)" instead of the literal `plan|implement|ship`; `plan_path` becomes **`artifact_path`**, "absolute path to the run's primary durable artifact (a committed plan, a committed RCA, a report), or null". State explicitly that **no orchestrator code reads either key** (verified: `ap-cycle.sh` takes `plan_path` from the decider's `planPath`, `ap-resume.sh` from the parked registry, `ap-runs.py show` dumps the file verbatim) — so the feature path may keep emitting `plan_path` until the follow-up plan migrates it, and both keys coexisting is harmless.
  - `## Local queue contract` (from `:156-195` + `:226-281`) — everything **except** the `**States**` bullet (`:195-225`, plan-critic-corrected offset), which is feature-path-specific and stays in `autopilot-protocol.md`. Keep the single `$QUEUE_PY` resolution snippet here as its one authoritative home.
  - `## Ask→fallback rule` (from `:283-300`) — unchanged.
  - `## Linear footprint` (from `:302-320`) — unchanged. Add one sentence: the bug path's Linear footprint is identical (claim + `agent:ready-to-test` label, never a comment), and note that `mcp__linear-server__save_comment` is **not** on the allow list, so `piv-investigate-issue`'s Linear-comment step is structurally impossible headlessly rather than merely forbidden.
- **IMPLEMENT (new content)**: `## Never end the turn with required local work in the background` — promote the rule currently duplicated in `implement-issue/SKILL.md:1309-1318` and `ship-work/SKILL.md:462-468` into one shared statement: the harness kills the session past its background-wait ceiling with no final `status.json`; run gates and waits as blocking foreground commands; treat the `status.json` write as the last thing that must complete; if a suite genuinely cannot finish in-turn, write an interim `FAILED` with `detail: "gates still running at turn end"` first.
- **IMPLEMENT (new content)**: `## Pipelines and their phase vocabularies` — three rows, not two (the third is the feature fork this table anticipates — `docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md` — which reuses this same piv state set rather than earning its own):

  | pipeline | selected by | phases (`status.json`'s `phase`) | states | lanes |
  |---|---|---|---|---|
  | legacy feature (**retired, inert once the feature fork ships**) | never dispatched after the feature-fork plan; reachable only by hand-setting a state | `plan`, `replan`, `implement`, `ship` | `planning`, `plan-review`, `building`, `shipping`, `ship-pending` | plan, build, ship |
  | piv — bug | `kind: bug` | `investigate`, `re-investigate`, `fix`, `review` | `piv-drafting`, `piv-draft-review`, `piv-implementing`, `piv-review-pending`, `piv-reviewing` | plan, build, review |
  | piv — feature | `kind: feature` (or absent) | `design`, `redesign`, `build`, `review` | *(the same five)* | plan, build, review |

  Shared states: `queued`, `needs-input`, `ready-to-test`, `failed`, `done`. Restate the invariants: **(a)** the piv state set and the legacy state set are disjoint, so a legacy-state ticket can only ever be claimed by legacy tiers and vice versa; **(b)** `kind` is read in exactly two places — the `queued` intake tier and the `piv-draft-review` tier, the only two states where both kinds sit and the next action differs; **(c)** phase names are globally unique across all three pipelines, which is what lets `phase_at_question` route tier 3 and what lets `REQUEUE_STATE` be a flat map. Until the feature fork ships, the middle row is the only piv row in production and the third row is aspirational — this document is written so that lands as a state-machine no-op when it does.
- **IMPLEMENT**: A `## Phase-name constraint` note: a phase name must contain **no underscore** — `ap-runs.py:80-82`'s `_ACT_WINDOW_RE` uses `(?P<phase>[^_]+)` against an underscore-delimited window name, so `re_investigate` would silently stop `ap runs`/`ap status`/`ap tail` from seeing the act. Hence `re-investigate`.
- **PATTERN**: `claude/skills/autopilot-protocol.md` (whole file) — same voice, same "defined once here so each skill only states what maps to what" framing (`:5-7`).
- **IMPORTS**: n/a (markdown).
- **GOTCHA**: Naming. `headless-protocol.md` is accepted from the brief, with the split made honest: this file is *the* protocol, `autopilot-protocol.md` becomes the feature-path addendum that points here. Rejected `autopilot-headless-core.md` (verbose, and "autopilot" is the thing being generalized away from) and extending `autopilot-protocol.md` in place (the `States` section must stay verbatim for the live legacy consumers, which is exactly what makes a split necessary).
- **GOTCHA**: Do **not** copy the sections and leave the originals. Two files describing `status.json` is the drift generator this whole task exists to remove.
- **VALIDATE**: `test -f /home/coder/coder-packages/claude/skills/headless-protocol.md && grep -c '^## ' /home/coder/coder-packages/claude/skills/headless-protocol.md`
- **SATISFIES**: AC #1

### UPDATE `scripts/install-autopilot.sh` — wire the new doc (first pass)

- **IMPLEMENT**: Add `headless-protocol.md` to `SKILL_NAMES` (`:281`) and to `EXCLUDE_BODY` (`:328-334`). Then run the installer so the symlink exists before Phase 2.
- **PATTERN**: `scripts/install-autopilot.sh:281` and `:328-334` — note `test-issue` is in `SKILL_NAMES` but missing from `EXCLUDE_BODY`, a pre-existing inconsistency; do not copy it. Add every new name to **both**.
- **GOTCHA**: `--check` must stay meaningful: run `./scripts/install-autopilot.sh --check` after and confirm it reports converged.
- **VALIDATE**: `cd /home/coder/coder-packages && ./scripts/install-autopilot.sh && ./scripts/install-autopilot.sh --check && readlink /home/coder/root-for-local/.claude/skills/headless-protocol.md`
- **SATISFIES**: AC #1

### UPDATE `claude/skills/autopilot-protocol.md` — reduce to the feature-path addendum

- **IMPLEMENT**: Replace the header (`:1-17`) with: this document is the **feature-path (plan/build/ship) addendum** to `.claude/skills/headless-protocol.md`; **read that first** — it defines the trigger, the `dontAsk` discipline, the status vocabulary, parking, `status.json`, the queue contract, the ask→fallback rule, the Linear footprint, and the background-work rule. Keep here: the `**States**` bullet (`:195-225`, plan-critic-corrected offset) verbatim, `## Orchestrator guarantees` (`:322-351`) verbatim, and the launch-mechanism paragraph (`:12-17`). REMOVE every section moved in the previous task.
- **PATTERN**: the pointer-sentence style of `implement-issue/SKILL.md:1139-1142`.
- **GOTCHA**: **Hold `ap pause` for this edit and the next two.** A live act mid-turn may re-read this file; the pointer must be the first thing it sees, and the target must already resolve.
- **GOTCHA**: Do not touch the `States` bullet's content. `shipping` being orchestrator-written (`:203-209`) and the `ship-pending` semantics (`:215-225`, plan-critic-corrected offset) are still exactly right for the feature path.
- **VALIDATE**: `grep -n 'headless-protocol.md' /home/coder/coder-packages/claude/skills/autopilot-protocol.md && grep -c 'planning' /home/coder/coder-packages/claude/skills/autopilot-protocol.md`
- **SATISFIES**: AC #1

### UPDATE `claude/skills/implement-issue/SKILL.md` — repoint, de-duplicate

- **IMPLEMENT**: At `:1139-1142`, change the pointer to name both docs: read `headless-protocol.md` first for the mechanics, then `autopilot-protocol.md` for this pipeline's own states and orchestrator guarantees. **REMOVE** the duplicated `$QUEUE_PY` snippet at `:1144-1149`, replacing it with one sentence: resolve `$QUEUE_PY` once per the protocol's local-queue contract before any write. **REMOVE** the duplicated background-work paragraph at `:1309-1318`, replacing it with one pointer sentence to the new doc's section.
- **PATTERN**: `ship-work/SKILL.md:394-396` — the shorter of the two existing pointers; it already assumes `$QUEUE_PY` was resolved without restating it, which is the behavior being standardized on.
- **GOTCHA**: Behavior-preserving only. Do not touch `--phase plan`/`--phase implement`'s ask mappings, end states, `--ports`/CORS rule, or step 7b.
- **VALIDATE**: `grep -n 'readlink -f' /home/coder/coder-packages/claude/skills/implement-issue/SKILL.md` (expect: no hit inside the headless section) and `grep -n 'headless-protocol.md' /home/coder/coder-packages/claude/skills/implement-issue/SKILL.md`
- **SATISFIES**: AC #1

### UPDATE `claude/skills/ship-work/SKILL.md` — repoint, de-duplicate

- **IMPLEMENT**: Same two-doc pointer at `:394-396`. **REMOVE** the duplicated background-work paragraph at `:462-468` in favour of a pointer.
- **PATTERN**: as above.
- **GOTCHA**: Leave the five hard stops → `NEEDS_HUMAN` mapping (`:413-432`) and the success end-state write (`:434-456`) exactly as they are — the new `piv-review-pr` section mirrors them, it does not replace them.
- **VALIDATE**: `grep -n 'headless-protocol.md' /home/coder/coder-packages/claude/skills/ship-work/SKILL.md`
- **SATISFIES**: AC #1

### UPDATE `autopilot/bin/ap_queue.py` — `kind`, new states, multi-state list, `--kind`

- **IMPLEMENT**:
  1. `STATES` (`:26-29`) gains `"piv-drafting"`, `"piv-draft-review"`, `"piv-implementing"`, `"piv-review-pending"`, `"piv-reviewing"`. Add a comment splitting the set visually into shared / legacy-feature-path / piv (both kinds), and stating the disjointness invariant.
  2. New module constants `KINDS = {"feature", "bug"}` and `DEFAULT_KIND = "feature"`.
  3. New `ticket_kind(entry)` → `entry.get("kind") or DEFAULT_KIND`, with a docstring stating that a ticket file written before this field existed reads as `feature`, which is the intended back-compat (every ticket on disk today ran the feature path).
  4. `new_ticket(...)` (`:116-136`) gains a `kind="feature"` keyword, placed after `note`/`auto_approve` and before `actor` so existing positional callers are unaffected; the entry dict gains `"kind": kind if kind in KINDS else DEFAULT_KIND` and a new `"artifact_path": None` field alongside the legacy `plan_path`, with a comment: **the piv fork's artifact — a committed RCA for a bug, a committed implementation plan for a feature — resolved kind-specifically by the decider; `plan_path` stays for the inert legacy path only.** The `queued` history event becomes `f"queued ({kind})"`.
  5. `list_queue(ap_home, state=None)` (`:93-108`) accepts `state` as a string **or** an iterable of strings; keep the existing string behavior byte-identical. Implement as: normalize to a set when not a string, then `if states and entry.get("state") not in states: continue`. Docstring: the ordering contract (oldest-first by `seq`) is unchanged and is what makes a multi-state scan fair across forks.
  6. CLI `new` subparser (`:234-237`) gains `--kind`, `choices=["feature","bug"]`, `default="feature"`; the handler (`:264-271`) passes it through.
  7. **`transition()` must validate a written `state` against `STATES` before writing it**, instead of the current bare `entry.update(**fields)`. Reject (or at minimum log loudly and refuse) a `state` value not in `STATES`. One-line-scale fix; makes the entire class of state-name drift this migration is full of — a stale bug-fork name, a typo, a future rename missed in one file — loud instead of silent.
  8. **`ticket_kind()` must validate against `KINDS`, not just check truthiness** — this supersedes sub-item 3's naive `entry.get("kind") or DEFAULT_KIND` definition. Replace it with the equivalent of `value = entry.get("kind"); return value if value in KINDS else DEFAULT_KIND`. A present-but-invalid value (`"Bug"`, `"BUG"`, a stray `true`/`1` from a hand-edit or a future bug in `ap queue`'s own parsing) is truthy today and passes through as itself, silently failing every `== "bug"` check and running a bug ticket through the feature-plan path, which has no root-cause diagnosis step. Preserves back-compat: a genuinely *missing* key still defaults to `feature`, so every existing ticket is unaffected — only the present-but-garbage case is newly caught.
- **PATTERN**: `ap_queue.py:154-176` (`set_note`) for how a new keyword arg with back-compat semantics is documented in this file; `:139-151` (`force_state`) for get-or-create framing.
- **IMPORTS**: none new.
- **GOTCHA**: `force_state` (`:139-151`) and `set_note` (`:154-175`) both call `new_ticket` for a ledger-only row. They must **not** guess a kind — they get the `feature` default, which is correct (a ledger-only row predates classification) and must be stated in a comment so nobody later "fixes" it into an inference.
- **GOTCHA**: Do not add `kind` validation to `transition()`. It applies `**fields` blindly by design (`:178-191`) for every field *except* `state` (sub-item 7's narrow addition), and `ap sessions`' status picker feeds it from `sorted(ap_queue.STATES)` — adding validation for fields in general would be a new failure mode for the dashboard.
- **GOTCHA — superseded by sub-items 7-8 above, found by red-teaming this plan (see `ADVERSARIAL REVIEW`).** An earlier draft of this task said "`transition()` applies `**fields` blindly by design — no validation to add, same as Phase 1's note on `kind`" (the GOTCHA immediately above, before this correction). That is no longer the whole story: `transition()` now gains the narrow `state`-only `STATES` check (sub-item 7), because once tier 5 dispatches through a `kind`-branched action instead of a hardcoded constant, a stale or mistyped state name would otherwise write silently. The original concern — that `transition()` shouldn't validate fields *generically* — still holds for every field except `state`, whose value space is a closed, enumerable set with real downstream consumers (`ap sessions`' picker, every decider tier, `sweep_stale`) that already assume closure. `kind` gets its validation in `ticket_kind()` instead (sub-item 8), not in `transition()` — the two fixes are deliberately in different places for that reason.
- **VALIDATE**: `cd /home/coder/coder-packages/autopilot/bin && python3 -c "import ap_queue; print(sorted(ap_queue.STATES)); print(ap_queue.ticket_kind({})); print(ap_queue.ticket_kind({'kind':'bug'})); print(ap_queue.ticket_kind({'kind':'Bug'}))"` → the last line must print `feature`, not `Bug`
- **SATISFIES**: AC #2, AC #3

### CREATE `autopilot/tests/test_queue.sh`

- **IMPLEMENT**: Direct unit tests for the above: `new_ticket` default kind is `feature`; `--kind bug` sets `bug`; an invalid `--kind` is rejected by argparse (exit non-zero); a hand-written ticket file with no `kind` key reads as `feature` via `ticket_kind`; `list_queue` with a string state behaves exactly as before; `list_queue` with a two-state iterable returns both, seq-ordered oldest-first; a fresh ticket carries `artifact_path: null`.
- **PATTERN**: `autopilot/tests/test_decide.sh:1-19` (harness header, `pass`/`fail`/`assert`) and `:43-61` (`seed_ticket` via a `python3 - <<'PY'` heredoc with `sys.path.insert(0, bin_dir)`). Final block: `test_cycle.sh`'s trailing `ALL PASS` / `N FAILURE(S)` + exit code.
- **GOTCHA**: `mktemp -d` per case and never touch the real `$AP_HOME` — every existing harness does this, and this one runs `ap_queue.py` writes directly.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_queue.sh`
- **SATISFIES**: AC #2, AC #12

### UPDATE `autopilot/bin/ap-runs.py` — `--kind` at intake, new states in every reader

- **IMPLEMENT**:
  1. `queue` subparser (`:1704-1708`) gains `--kind` with the same `choices`/`default`; `cmd_queue` (`:1424-1436`) passes it to `new_ticket` and its success line prints the kind: `queued ENG-1400 (seq 12) [bug]`.
  2. `_action_queue_new_curses` (`:980-996`) prompts for kind after the note — a single-key `[f]eature/[b]ug` prompt defaulting to feature on Enter (a free-text popup for a two-value field is worse than a keypress here), and the confirmation popup names it.
  3. `QUEUE_DASHBOARD_STATES` (`:427`) gains `"piv-draft-review"` and `"piv-review-pending"` — these are the two bug-path states that **await a decision or a claim** and belong in the dashboard's action-needed set, exactly as `plan-review`/`ship-pending` do.
  4. `PENDING_STATES` (`:1063`) gains `"piv-draft-review"` — it is the bug path's approval gate, the direct analogue of `plan-review`.
  5. `_queue_note` (`:518-555`): `piv-draft-review` mirrors the `plan-review` branch exactly (auto-approve on / approved — piv-implementing next cycle / awaiting `ap approve`); `piv-review-pending` → `"PR open, review still owed -- will review automatically next cycle"`; and the "no live session for this state" fallback (`:553`) gains `piv-drafting`, `piv-implementing`, `piv-reviewing`.
  6. `REQUEUE_STATE` (`:1378-1383`) gains `"investigate": "queued"`, `"re-investigate": "queued"`, `"fix": "piv-draft-review"`, `"review": "piv-review-pending"` — this is what `ap retry` does for a FAILED bug act, and it must match `ap-cycle.sh`'s external-failure requeue map exactly.
  7. `_ACT_WINDOW_RE` (`:80-82`) gains `review_\d+`: `r"^act_(?:plan|build_\d+|ship_\d+|review_\d+)_(?P<issue>[^_]+)_(?P<phase>[^_]+)$"`.
  8. `_action_approve_curses` (`:891-892`) and `_action_feedback_curses` (`:899-901`, plan-critic audit correction — this function is named `_action_feedback_curses`, not `_action_reply_curses`) accept `piv-draft-review` alongside `plan-review`, with the not-applicable messages updated.
- **PATTERN**: each edit mirrors the `plan-review`/`ship-pending` line immediately adjacent to it.
- **GOTCHA**: `TERMINAL_STATES` (`:833`) does **not** change — `ready-to-test`/`done`/`failed` remain the terminals for both forks.
- **GOTCHA (plan-critic audit)**: `ap-runs.py` has a **fifth** phase-name reader this task's own file list doesn't enumerate — a oneshot-mode live-act phase-label heuristic around `:155-167` that derives a display label from the `-p /<skill>` invocation token, special-casing only `implement-issue --phase` and `ship-work` prompts. Left unmodified, a live `/piv-investigate-issue` act would be labelled `piv-investigate-issue` in `ap runs`/`ap status` rather than `investigate`. Accepted as a **known, cosmetic gap** for this pass (oneshot-mode display only, no state or dispatch impact) rather than adding a sixth site to an already-large task — revisit if `ap status`'s bug-act labels turn out to matter more than expected in practice.
- **GOTCHA**: `ap approve`'s underlying `approve_ticket` (`ap_queue.py:194-204`) never checked state and still shouldn't; only the curses guard does. Keep it that way — the decider is the thing that discriminates, per `reply_ticket`'s own docstring (`:207-211`).
- **VALIDATE**: `cd /home/coder/coder-packages/autopilot/bin && python3 -m py_compile ap-runs.py && python3 ap-runs.py queue --help | grep -- --kind`
- **SATISFIES**: AC #2, AC #3, AC #10

### ADD `autopilot/bin/ap-env.sh` — `AP_REVIEW_SLOTS`

- **IMPLEMENT**: After the `AP_PLAN_SLOTS` block (`:113-121`), add `AP_REVIEW_SLOTS`, **default 2, clamped 1..4**, using the identical five-branch clamp idiom. Comment must state the reasoning: the review lane runs `piv-review-pr` → `debate-review` → `babysit-pr`. Unlike ship (almost pure CI-wait, capped 6), a review act runs the repo's **real** validation suite in `piv-review-pr`'s Phase 3 and again per `babysit-pr` repair push, which is CPU-heavy like a build; but unlike build it also spends long stretches purely waiting on bot rounds (`babysit-pr/SKILL.md:100-105`: bots post 5-10 min after a push, 8-15 for Codex). So it earns more than plan's 1 and no more than build's 4 — default 2, matching build.
- **PATTERN**: `ap-env.sh:84-92` (`AP_SHIP_SLOTS`) — same shape, same "why this cap differs" comment discipline.
- **IMPORTS**: n/a.
- **GOTCHA**: No `review_lock_file()` helper. Plan needed one only because slot 1 keeps the legacy `lock.plan` path (`:108-112`); review has no legacy occupant, so `$AP_HOME/lock.review.$n` inline is correct and consistent with build/ship.
- **VALIDATE**: `bash -c 'AP_REVIEW_SLOTS=99 source /home/coder/coder-packages/autopilot/bin/ap-env.sh; echo $AP_REVIEW_SLOTS'` → `4`; repeat with `abc` → `2`, `0` → `1`.
- **SATISFIES**: AC #4

### ADD `autopilot/bin/ap-cycle.sh` — review lane probe, lock, ports, window name

- **IMPLEMENT**:
  1. Extend the lane-comment block (`:163-176`) and the probe section (`:227-273`): `busy_review`/`free_review_slot` loop over `AP_REVIEW_SLOTS` on `$AP_HOME/lock.review.$n`, lowest-first, `busy_lanes` gains `review`.
  2. New `review)` arm in the action case statement (`:460-511`): `act_lane="review"`, `review_slot="$free_review_slot"`, `act_lock_file="$AP_HOME/lock.review.$review_slot"`, `fe_port=$((5187 + review_slot))`, `be_port=$((8020 + review_slot))`. Comment the range choice: build occupies 5174-5177/8001-8004 (slots ≤4), ship 5181-5186/8011-8016 (slots ≤6), the human's baseline is 5173/8000 — so 5187/8020 is the next non-overlapping base. Like ship, `piv-review-pr` serves no UI, so these ports exist only to isolate its local gates from a concurrent build; the CORS allowlist is irrelevant for the same reason (`:500-506` states this for ship).
  3. Declare `review_slot=""` alongside `build_slot`/`ship_slot` at `:456-458`.
  4. `window_name_for` (`:595-603`) gains `review) printf 'act_review_%s_%s_%s' "${review_slot:-0}" "${issue:-unknown}" "$phase" ;;`.
- **PATTERN**: the `ship)` arm at `:484-510` — the closest analogue (own lane, own ports, no UI server) and its comment explains precisely why the ports still matter.
- **GOTCHA**: The `review)` arm must sit in the same case statement as `ship)` and must **not** be reachable from a `fix` act. Add the mirror-image of ship's own warning comment: a bug's `fix` act never chains into review; `review` is only ever a fresh cycle's decided action, so it always gets its own lane/slot/ports.
- **GOTCHA**: `AP_SHIP_SLOTS` clamps to 6, so ship can reach 5186. Do not pick 5185.
- **GOTCHA**: The review lane's ports are provisioned for isolation-safety and consistency with the ship lane's own reasoning, but are likely **unused in practice** — nothing in `piv-review-pr`'s Phase 3 (which runs through `piv-validate`) or `babysit-pr` binds a server. Keep them (cheap, and matches the pattern every other lane follows), but don't describe them in the README/protocol docs as load-bearing for this lane the way they genuinely are for build.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-cycle.sh && shellcheck /home/coder/coder-packages/autopilot/bin/ap-cycle.sh`
- **SATISFIES**: AC #4, AC #11

### UPDATE `autopilot/bin/ap` — review lane in status, down, limits, usage

- **IMPLEMENT**:
  1. `cmd_status` (`:320-329`): add `review_lock_file()` next to `build_lock_file`/`ship_lock_file` and a fourth `lane_slot_line "review slots:" 12 "$AP_REVIEW_SLOTS" review_lock_file`.
  2. `cmd_status`'s in-flight window regex (`:343`): `^act_(build|ship|review)_([0-9]+)_(.+)_([^_]+)$`.
  3. `cmd_down` (`:228-247`): a `review_busy` loop over `AP_REVIEW_SLOTS`, appended to `$busy`. **Load-bearing** — without it `ap down` silently kills a live review act, the exact failure the refusal exists to prevent.
  4. `cmd_limits` (`:613-661`): `--review-slots` → `AP_REVIEW_SLOTS`, a `review slots (clamped 1-4):` line in the report, and the flag in the printed usage.
  5. `usage()` (`:19, 38-42`): mention `--review-slots`.
- **PATTERN**: `ap:320-329`, `:234-237`, `:623`, `:636` — every one is a one-line sibling of an existing ship line.
- **GOTCHA**: `lane_slot_line` communicates the busy count via **return code** (`:318`) and `cmd_status` captures it with `$?` immediately after (`:324`). Insert the review line **after** the ship line, and do not let anything sit between a `lane_slot_line` call and a `$?` read.
- **VALIDATE**: `ap limits | grep -i review && ap status | grep -i 'review slots' && shellcheck /home/coder/coder-packages/autopilot/bin/ap`
- **SATISFIES**: AC #4, AC #10

### ADD `claude/skills/piv-investigate-issue/SKILL.md` — step 7: the conditional adversarial gate

- **IMPLEMENT**: A new numbered step **after** step 6 (Propose Fix Approach, `:88-96`) and **before** the RCA output section, titled `### 7. Adversarial gate — ONLY when a trigger fires`. Two independent conditional dispatches:

  **Order matters: challenge the diagnosis before red-teaming the fix — 7a is `/challenge`, 7b is `/red-team`.** (Codex's independent second draft, Phase 5c, made this point and it holds: a challenge-driven revision to the root cause can change what the proposed fix actually does, which would make a red-team pass run *before* that revision stale or wasted. Diagnosis gets stress-tested first; the fix derived from it gets stress-tested second, after any revision the diagnosis check produced.)

  **7a. `/challenge` the root-cause reasoning — only when it rests on a measurement.** Bold *Conditional*, and **state plainly that this trigger is a new convention introduced by this plan — `/challenge` has no existing wiring anywhere in this codebase, so nothing here is inherited from a working precedent.** Trigger, made mechanically checkable: scan the RCA's Evidence Chain (5 Whys) and Impact Assessment; if **any load-bearing link** cites something other than a `file:line` reference — a count, a rate, a dashboard figure, a log volume, a query result, a time-window comparison, a dataset conclusion — the trigger fires for that link. If every link is `file:line`, it does not. Dispatch a fresh `Agent` carrying `/challenge`'s rubric with the claim written as one falsifiable sentence plus the field/window/population it rests on, and **none of the reasoning that produced it** (`challenge/SKILL.md:133-144`). Require back its §8 report: verdict, what was checked, the corrected claim if it changed, residual risk. **If the corrected claim changes the root cause, revise "Proposed Fix" before 7b runs** — 7b must evaluate the (possibly revised) fix, not the pre-challenge one.

  **7b. `/red-team` the proposed fix — only when it touches a guard.** Bold *Conditional. Skip it and say so unless the trigger fires.* Trigger, verbatim from `implement-issue/SKILL.md:360-365`: the proposed fix changes the behaviour of any of — a verifier or postcondition, a validator, a dispatcher/entry gate, a cap or budget check, a permission or entitlement check, a dedupe/idempotency key, a retry or fallback branch, or a default deciding whether work happens at all. Classify from the RCA's own "Files to Modify" and "Fix Strategy" sections; **when genuinely uncertain, run it.** Dispatch a **fresh** `Agent` carrying `/red-team`'s rubric (model `fable` or `opus`, effort matching the RCA's Complexity), given: the fix stated as a behaviour delta (§0 of the rubric: *"after this change, X will happen where Y happened before"*), the guard's current code and tests, and **explicitly not the RCA's own argument for why the fix is right**. Require back the same five items `implement-issue`'s step 7b requires (must-stay-fatal list, discriminator attack, replay, blast radius, already-solved check).

  **Both**: fold findings into the RCA under the new `## Adversarial review` section (next task), **including a recorded non-firing trigger, so every skip is auditable**. Verdict routing: red-team `do not ship as specified` or challenge `does not survive` → **do not proceed to the RCA-ready state**; this is a blocking finding (headless mapping in the headless section). `ship with the named additions` / `stands with caveats` → fold the additions into "Proposed Fix" and proceed.
- **PATTERN**: `implement-issue/SKILL.md:354-399` — copy its structure exactly: bold conditional warning, enumerated trigger, a *why this exists and the cheaper check doesn't cover it* paragraph (here: the RCA's own Confidence field asks "how sure am I of the cause?", which is a different question from "what does this fix now let through?" — a HIGH-confidence RCA can carry a fix that turns structurally-broken cases green, which is the ENG-1406 case recorded at `implement-issue/SKILL.md:370-377`), the fresh-agent dispatch with the argument withheld, the numbered require-back list, and the auditable-skip rule.
- **IMPORTS**: n/a.
- **GOTCHA**: `/red-team`'s §3 replay ("do not reason about the change's reach, compute it", `red-team/SKILL.md:79-91`) usually **cannot run headlessly** — the `dontAsk` profile allows no MongoDB read tools and no piped queries. Instruct the sub-agent explicitly: if the historical rows cannot be obtained, **that gap is itself the finding** and must be reported as such, never reasoned around. This is exactly the wording `implement-issue/SKILL.md:388-390` already uses.
- **GOTCHA**: Both dispatches are sub-agents inside the investigate act, not separate acts. They write no `status.json` and no queue entry.
- **GOTCHA**: This step is interactive-first by design. Put the *trigger and dispatch* here, not in the headless section — only the verdict→state mapping is headless-specific. Same division as step 7b in `implement-issue`.
- **VALIDATE**: `grep -n 'Adversarial gate\|do not ship as specified\|does not survive\|new convention' /home/coder/coder-packages/claude/skills/piv-investigate-issue/SKILL.md`
- **SATISFIES**: AC #13, AC #14

### ADD `claude/skills/piv-investigate-issue/SKILL.md` — `## Adversarial review` in the RCA template

- **IMPLEMENT**: Inside the RCA document template (`:105-244`), after `### Risks and Considerations` (`:215-219`) and before `### Testing Requirements`, add:

```markdown
## Adversarial review

### Challenge (measurement-backed root causes only) — runs first

**Trigger**: fired / did not fire — <which evidence-chain link is not a file:line reference, or
"every link is file:line">
<If fired: verdict · instrument/window/proxy/join/sample findings · the corrected claim with the
old figure named · residual risk>

### Red-team (guard-touching fixes only) — runs second, against any challenge-driven revision

**Trigger**: fired / did not fire — <which guard class, or why none applies>
<If fired: verdict · must-stay-fatal list with how each is preserved · discriminator attack ·
replay result (or "rows unobtainable — recorded as a finding") · blast radius, enumerated ·
what the fix can drop · what changed in "Proposed Fix" as a result>
```

- **PATTERN**: the template's existing heading style, and `implement-issue`'s "record the trigger decision when it did not fire, so the skip is auditable" (`:396-397`).
- **GOTCHA**: A did-not-fire record is **mandatory**, not optional. A missing section is indistinguishable from a skipped step, which is what makes the conditional trustworthy over time.
- **VALIDATE**: `grep -n 'Adversarial review' /home/coder/coder-packages/claude/skills/piv-investigate-issue/SKILL.md`
- **SATISFIES**: AC #13

### ADD `claude/skills/piv-investigate-issue/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: New section at the end of the file. Contents, in order:
  1. **The pointer sentence**, verbatim in shape from `implement-issue/SKILL.md:1139-1142`, naming `headless-protocol.md`. Nothing about `status.json`, `dontAsk`, or ask→fallback mechanics is restated.
  2. **Phase**: `investigate` (or `re-investigate` when `--feedback` is present). `phase_at_question: "investigate"` on every `NEEDS_HUMAN`.
  3. **Input is always an existing Linear issue id.** No free-text path headlessly.
  4. **Worktree + branch mandate, first thing** — the single most important headless override, because the interactive skill has no branch discipline at all and the main checkout is unusable: reuse the ticket's worktree if one exists (`git worktree list | grep "wt-eng<id>-"`), else create `wt-eng<id>-root` (plus one per additional repo the RCA touches) off the repo's real base (`dev` for root/`backend/`/`frontend/`, `main` for `assistants/`/`observability/`, confirmed per repo, never assumed), on branch **`haroun/eng-<id>-fix-<slug>`**. Never work in the main checkout. Three reasons, all verifiable: the main checkout is permanently dirty and sits on an unrelated branch (`fix/eng-1476-e2e-python-version` at the time of writing), so every dirty-tree and branch heuristic downstream mis-fires; `AP_BUILD_SLOTS > 1` means two acts must never share a checkout; and the `dontAsk` profile only permits `git push -u origin haroun/*`, so any other prefix is denied at push time.
  5. **Linear claim + kata mirror, first thing**: claim (`assignee: me`, `state: In Progress`) and run step 1b's kata search/create + `work.attention ok` + `work.branch haroun/eng-<id>-fix-<slug>`, unconditionally, `--feedback` re-runs included (both are harmless no-ops when repeated). This is the only place the Linear claim can happen for a bug ticket — `ap-decide.py` has no Linear credential. Mirrors `implement-issue/SKILL.md:1191-1200`.
  6. **Ask-point mapping table**:

     | ask point | headless resolution | recorded as |
     |---|---|---|
     | Already closed (`:265`) | documented default: proceed, write the RCA anyway | `history` event `"issue already closed — RCA written anyway"`, plus `detail` |
     | Already has a linked PR (`:266`) — *bare ask, no stated default; one is invented here* | documented default: **proceed** and record it, **unless** the linked PR is open and touches a file the RCA's own "Files to Modify" names — then `NEEDS_HUMAN`, quoting the PR URL and the overlapping files | `history` + `detail`; or `question` on the escalation |
     | Can't pin the root cause / Confidence stays LOW after the Codex read-only corroboration attempt (`:267-282`) | already headless-shaped: write the RCA with the best hypothesis and what's uncertain, **and additionally** `NEEDS_HUMAN` — because the RCA's own Confidence:LOW is a hard stop for `piv-implement-issue` (`:73-76`), so proceeding to `piv-draft-review` would only park the ticket one phase later having spent a whole fix act to rediscover it | `question` = the specific unknown that would raise confidence; kata `work.attention needs-human` |
     | Scope too large (`:283`) | documented default: keep the RCA on the core problem, list the rest as out-of-scope; do not split, do not create Linear issues (creation is interactive-only per the protocol) | `detail` + the RCA's own out-of-scope list |
     | Step 7a challenge `does not survive`, or 7b red-team `do not ship as specified` | `NEEDS_HUMAN` — never a silent override | `question` = the verdict plus the single most load-bearing finding; the full findings live in the RCA's `## Adversarial review`; kata `work.attention needs-human` |
     | Linear comment step (`:246-258`) | **skipped entirely** — headless runs never post a Linear comment, and `mcp__linear-server__save_comment` is not even on the allow list | n/a |

  7. **Commit the RCA before the queue write.** The RCA must be committed on the ticket's branch in its worktree — the fix act is a different session, potentially hours later, and reads it from disk; an uncommitted artifact would also leave the worktree dirty and trip the fix act's own precondition checks. Same discipline as the plan phase committing its plan (`implement-issue/SKILL.md:1202-1204`).
  8. **End state**: after the commit, one write —
     ```bash
     python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state piv-draft-review \
       --field artifact_path=/absolute/path/to/docs/issues/issue-<ENG-ID>.md \
       --event "RCA ready for review"
     ```
     then `status.json` with `status: DONE`, `phase: "investigate"`, `artifact_path` = the RCA path. Add the same emphatic warning the plan phase carries: **without this write the ticket never leaves `piv-drafting` and the pipeline stalls after every investigation** — do not skip it or reorder it before the commit lands.
  9. **`--feedback '<text>'`**: treat as new information about the bug, not a mechanical correction. Revise the RCA in place (same file, same branch, a new commit) and **re-run step 7's triggers against the revision** — a revised fix strategy can newly touch a guard, or newly lean on a metric. Then re-record `artifact_path` and write `DONE` as above.
- **PATTERN**: `implement-issue/SKILL.md:1160-1231` (`--phase plan`) — nearly a structural template: input rule, claim+kata, ask table, end-state write, blocking-question branch, `--feedback` handling.
- **GOTCHA**: `piv-investigate-issue`'s Codex corroboration (`:267-282`) shells out to `node .../relay.mjs`. `Bash(node *)` is **not currently on the allow list** (unlike `git`, `node` has no `-C`-style escape hatch already granted) — the Phase 8 task adds it. Until then this step is denied; the skill must treat a denial as "corroboration unavailable, note it and continue", not as a failure, exactly as `piv-implement-issue:154` already does for its own Codex pass.
- **GOTCHA**: `docs/issues/` is untracked in the work repo's main checkout today. In a fresh worktree it will not exist — create it before writing.
- **VALIDATE**: `grep -n 'Headless mode\|piv-draft-review\|haroun/eng-\|headless-protocol.md' /home/coder/coder-packages/claude/skills/piv-investigate-issue/SKILL.md`
- **SATISFIES**: AC #13, AC #14, AC #15

### ADD `claude/skills/piv-implement-issue/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: New section at the end. Contents:
  1. The pointer sentence.
  2. **Phase**: `fix`. `phase_at_question: "fix"`. **`--rca <path>` is always explicit**; a headless invocation without it is `FAILED`, `detail: "headless requires an explicit RCA path"`, no queue write.
  3. **This one act runs three skills.** After this skill's own steps complete, the same session runs **`/piv-commit`** and then **`/piv-create-pr`**, and only then writes `status.json`. Rationale, stated in the section: neither has a human-judgment ask point (`piv-commit` has none at all; `piv-create-pr`'s preconditions are deterministic fail-fast checks), so giving each its own act would add two dispatches, two states, and two park points for zero decision value.
  4. **Re-entry must be idempotent** — a retried `fix` act (external-failure requeue, or `ap retry`) re-enters from `piv-draft-review`. Before implementing anything: if the ticket's branch already exists and already carries a commit whose message contains `Part of ENG-<id>`, **skip to `/piv-create-pr`** rather than re-implementing. `piv-create-pr`'s own "existing PR already open → print the URL" precondition is then a `DONE`-idempotent success, not a failure. Without this rule a retry re-implements a fix that already landed.
  5. **Ask-point mapping table**:

     | ask point | headless resolution | recorded as |
     |---|---|---|
     | RCA drift check (`:46-54`) — hard stop | `NEEDS_HUMAN`, `question` = the drifted files with the RCA's expected vs actual, and "re-run `/piv-investigate-issue ENG-<id>`" | `question`, kata `needs-human`, `work.attention_msg` |
     | Confidence:Low in the RCA's Assessment table (`:73-76`) — hard stop, machine-checkable | `NEEDS_HUMAN` **before any code is written**: read the RCA's Confidence field first, branch on it | `question` = "RCA confidence is LOW; the root cause needs confirming before a fix" |
     | Branch selection (`:56-66`) | **overridden entirely**: reuse the worktree/branch `piv-investigate-issue` created (`haroun/eng-<id>-fix-<slug>`); if it is missing, create it the same way rather than falling through to the interactive heuristics | `history` event on a re-create |
     | Dirty tree on the base branch (`:66`) — bare ask, no stated default | **`FAILED`**, `detail` = the `git status -sb` output. Reasoning stated in the section: auto-choosing commit-or-stash silently mutates a human's uncommitted work, the one class of action this protocol exists to prevent; and `NEEDS_HUMAN` is the wrong shape because the remedy is git work at a terminal, which the `ap reply` channel cannot express — it would park a tmux window indefinitely. `FAILED` is the state whose semantics are "an error stopped the run; the wrapper decides whether to retry", and `ap retry` recovers it once the tree is clean. Note the cost honestly: `FAILED` increments `fail_count` and can auto-pause after two. Given the worktree mandate, a dirty tree here means a dirty *worktree* — a prior run's leftovers, which is genuinely worth pausing on. | `detail` |
     | Deviating from the RCA's plan (`:97-98`) | documented default: implement as specified; a forced deviation is recorded in the report's "Deviations from the RCA" section and in `detail`, never a stop | report + `detail` |
     | Validation fails (`:171-175`) | documented default: fix and re-run (bounded — after two full failing cycles, `NEEDS_HUMAN` with the failing output) | `question` on escalation |
     | Codex adversarial test pass (`:124-154`) | unchanged: a bonus check. `status: failed`/`codex_unavailable`/permission-denied → note in `detail` and move on. A genuine failing test means the fix is incomplete → back to step 3 with the specific gap, still inside this act | `detail` |
     | Linear implementation comment (`:276-282`) | **skipped** — never a Linear comment headlessly | n/a |
     | Linear state `Done` (`:284-285`) | already correct: never | n/a |
  6. **Report artifact path.** The output report (`:192-274`) gets a fixed path headlessly: **`docs/issues/reports/<ENG-ID>-fix-report.md`**, in the worktree, **committed by `/piv-commit` as part of the fix commit**. Reasoning stated: it must be inside the repo and committed, because (a) it is the reviewer's record of deviations and validation, which `piv-create-pr:57-59` already looks for and folds into the PR body, and (b) an uncommitted file would leave the tree dirty and trip `piv-create-pr`'s own "Uncommitted changes → STOP" precondition. Chose `docs/issues/reports/` over `.claude/reports/` because the latter is untracked in this work repo and would produce exactly that dirty-tree trap. Its absolute path goes in `status.json`'s `detail`, mirroring the QA-artifact convention (`implement-issue/SKILL.md:1276-1282`).
  7. **`--ports fe=<n>,be=<m>`**: if step 6's manual reproduction check starts the worktree servers, bind exactly those two ports (never the baseline 5173/8000) and start the worktree backend with `BACKEND_CORS_ORIGINS` set to a JSON list containing `http://localhost:<feport>` — this **replaces**, not extends, the default allowlist. **Stop them before writing `DONE` *or* `NEEDS_HUMAN`** (the protocol's parking rule: a slot freed at park time can be handed to a fresh act whose ports would collide). Verify with `ss -ltnp` before and after. Browser QA and the four-server baseline comparison are **not** required for the bug path — the fix's evidence is its reproduction case plus its regression test.
  8. **End state**: implement → tests → validate → **`/piv-commit`** → **`/piv-create-pr`** → `status.json` with `status: DONE`, `phase: "fix"`, `artifact_path` = the RCA path, `pr_urls` filled, `detail` = the fix-report path + the commit SHA. Record on the ticket in one write: `--field pr_urls='["<url>"]' --event "fix committed <sha>, PR open"`. **Do not change the ticket's `state`** — it stays `piv-implementing`; the wrapper swaps it to `piv-review-pending` after seeing this `DONE`.
- **PATTERN**: `implement-issue/SKILL.md:1233-1307` (`--phase implement`) — stop-condition mapping, ports/CORS rule, server teardown discipline, and the "do not change the state, the wrapper does" end-state note.
- **GOTCHA**: The RCA's Complexity:High → opus escalation (`:70-76`) still applies headlessly; the act's own pinned model is sonnet, and the escalation is a sub-agent dispatch, which is unaffected.
- **GOTCHA**: `git checkout -b` / `git switch` / `git rev-parse` all already pass under the current profile via the existing `Bash(git -C *)` allowance (e.g. `git -C <worktree> checkout -b ...`) — the plan-critic audit confirmed this by reading `autopilot/settings/autopilot.json` directly. Phase 8 does **not** need to add bare forms of these; use the `-C` form throughout this skill's git calls.
- **VALIDATE**: `grep -n 'Headless mode\|FAILED\|docs/issues/reports\|idempotent' /home/coder/coder-packages/claude/skills/piv-implement-issue/SKILL.md`
- **SATISFIES**: AC #15, AC #16

### UPDATE `autopilot/README.md` — concurrency, env vars, controls

- **IMPLEMENT**: Fourth row in the lanes table (`:206-209`): `review | lock.review.1 .. lock.review.N | AP_REVIEW_SLOTS, default 2, clamped 1-4 | piv-review-pr (debate-review + babysit-pr) for a bug-path PR`. A paragraph after the ship-lane one (`:220-232`) with the cap reasoning and the `5187+n`/`8020+n` range plus its non-overlap argument. `AP_REVIEW_SLOTS` in the env list (`:49-59`). `ap down`'s refusal wording (`:253-256`) and the `## Why supercronic -overlapping` lock list (`:346-352`) gain the review lane. New `### The bug path` subsection after `### Ship-only retry` (`:133-150`): the `--kind bug` classification, the three acts, the five states, and the one-line statement that the two forks' state sets are disjoint. Update the opening description (`:3-8`) to name both chains.
- **PATTERN**: `README.md:201-237` — the existing concurrency section's table-then-rationale structure.
- **GOTCHA**: Also fix `:49-59`'s omission of `AP_PLAN_SLOTS` if trivial; do not expand scope further.
- **VALIDATE**: `grep -n 'AP_REVIEW_SLOTS\|lock.review\|5187' /home/coder/coder-packages/autopilot/README.md`
- **SATISFIES**: AC #4, AC #10

### ADD `autopilot/bin/ap-decide.py` — `resolve_rca_path`

- **IMPLEMENT**: New function next to `resolve_plan_path` (`:38-55`): `entry["artifact_path"]` if it still exists on disk; else search `work_repo/wt-*-root/docs/issues/*.md` then `work_repo/docs/issues/*.md`, preferring an **exact case-insensitive** `issue-<eng-id>.md` basename match, falling back to a substring match on the full `eng-<n>` token; newest by mtime among ties; else `None`.
- **PATTERN**: `resolve_plan_path` (`:38-55`) — same two-tier worktree-then-root search, same mtime tie-break, same `None` contract.
- **IMPORTS**: `glob`, `os` (already imported).
- **GOTCHA**: Deliberately **not** a copy of `resolve_plan_path`'s glob. That one uses `*%s*.md % eng_lower`, which also matches `eng-1234` when looking for `eng-123` — a latent mis-resolution. Exact-match-first avoids inheriting it. Add a comment saying so (and that fixing the plan-path version is out of scope here).
- **GOTCHA**: RCA filenames are mixed-case (`issue-ENG-1124.md` exists in the work repo, alongside a legacy `issue-1510.md`). Compare lowercased basenames; never assume the case.
- **GOTCHA — the `rca_path`→`artifact_path` rename's negative-grep VALIDATE below must exclude `resolve_rca_path` itself.** `rca_path` is a literal substring of the function name `resolve_rca_path`, which stays named that way (it resolves an RCA specifically); a bare `grep 'rca_path\|rcaPath'` over this document will always show hits at every `resolve_rca_path` call site and can never pass as written. Exclude that function name explicitly: `grep -n 'rca_path\|rcaPath' docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md | grep -v resolve_rca_path` → expect no hits.
- **VALIDATE**: `cd /home/coder/coder-packages/autopilot/bin && python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('d','ap-decide.py'); m=importlib.util.module_from_spec(s); sys.modules['d']=m; s.loader.exec_module(m); print(m.resolve_rca_path({'eng_id':'ENG-9','artifact_path':None}, '/tmp'))"` → `None`
- **SATISFIES**: AC #5

### UPDATE `autopilot/bin/ap-decide.py` — tiers 1/2, both forks, seq-ordered

- **IMPLEMENT**: Replace tiers 1 & 2 (`:145-210`) with a single pass over **both** approval-gate states, `list_queue(ap_home, ("plan-review", "piv-draft-review"))` (seq-ordered, so the two forks interleave FIFO instead of one starving the other). Per entry, derive the fork from its state — `plan-review` → `(build lane, action "implement", claim state "building", artifact resolve_plan_path, decision key planPath)`, `piv-draft-review` → `(build lane, action "fix", claim state "piv-implementing", artifact resolve_rca_path, decision key artifactPath)` — then apply the existing logic unchanged: feedback wins over a stale approval; the feedback branch needs the plan lane free, the approve branch needs the build lane free; `_issue_lock_free` before any claim; unresolved artifact → `needs-input` + `continue`.
- **IMPLEMENT**: The feedback branch's action becomes `replan` for `plan-review` and `re-investigate` for `piv-draft-review`, claiming `planning` and `piv-drafting` respectively, both clearing `feedback` and carrying it in the decision.
- **PATTERN**: `ap-decide.py:145-210` verbatim in structure — the `build_busy and plan_busy` early skip (`:148-150`), the two-list `approve`/`feedback` split, the `for ... break` claim loop, and a `trace(...)` on every branch.
- **IMPORTS**: none new.
- **GOTCHA**: `_issue_lock_free`'s docstring (`:120-131`) applies **identically** to `piv-draft-review`: `piv-investigate-issue`'s headless end state writes `piv-draft-review` several steps before the wrapper notices `status.json` and releases `lock.issue.<id>`. Claiming inside that window orphans the claim (state flips to `piv-implementing`, no act is ever dispatched, recoverable only by the 3h sweep). This is the ENG-1327 failure recorded at `:174-181`. Do not skip the check for the new state.
- **GOTCHA**: Preserve `auto_approve` / `pending_approval` / `--auto-approve` env semantics for `piv-draft-review` exactly as for `plan-review`. `needs-input` is still never auto-approved.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_decide.sh`
- **SATISFIES**: AC #5, AC #6

### UPDATE `autopilot/bin/ap-decide.py` — tier 3 phase routing, tier 4 two lanes, tier 5 kind branch, stale sweep

- **IMPLEMENT**:
  1. **Tier 3** (`:212-243`): route by `phase_at_question` — `plan`/`implement`/absent → `replan` (unchanged); `investigate`/`fix` → `re-investigate` (claim `piv-drafting`, relay feedback); `ship`/`review` → skip with a trace line (needs the owner's interactive session or a tmux attach, exactly the existing `ship` reasoning at `:234-236`).
  2. **Tier 4** (`:245-269`): one pass over `list_queue(ap_home, ("ship-pending", "piv-review-pending"))`, seq-ordered, with a **per-entry** lane check (`ship-pending` needs the ship lane, `piv-review-pending` the review lane) so a busy review lane never blocks a free ship lane. `piv-review-pending` resolves its **PR URL** from `entry["pr_urls"][0]` rather than an artifact path; empty/missing → `needs-input` with `question: "Could not resolve the PR for this ticket."`, `phase_at_question: "review"`, then `continue` — mirroring the unresolved-artifact branch exactly. Claim `piv-reviewing`; decision `{"action": "review", "issue": eng_id, "prUrl": url}`.
  3. **Tier 5** (`:271-295`): after `list_queue(state="queued")`, branch on `ap_queue.ticket_kind(entry)` — `bug` → `piv-drafting` + `{"action": "investigate"}`, else `planning` + `{"action": "plan"}` (unchanged). Keep the `note` → `feedback` pass-through for both. Comment: **this is the only place in the decider that reads `kind`; every other tier is determined by state alone, because the two forks' state sets are disjoint.**
  4. **`sweep_stale`** (`:86-100`): the state tuple gains `"piv-drafting"`, `"piv-implementing"`, `"piv-reviewing"`. **Without this a crashed bug act is never recovered at all** — the 3h no-ledger-row-and-no-lock sweep is the only backstop for a workspace restart mid-run.
  5. Update the module docstring's tier summary (`:10-11`).
- **PATTERN**: `:245-269` (tier 4) for the resolve-or-needs-input-then-continue shape; `:282-283` for a lane-busy trace skip.
- **IMPORTS**: `ap_queue` already imported (`:26`).
- **GOTCHA**: Tier 4's existing implementation `break`s on the first claim. Keep that — one act per cycle is the whole design. With two states in one scan, the per-entry lane check must `continue` (not `break`) so a review-lane-blocked entry doesn't hide a claimable ship-pending one behind it.
- **GOTCHA**: The parked-registry exclusion at `:221-227` applies to bug tickets identically — a parked act is already sitting on the question and `scan_parked_replies` relays into it. Do not special-case.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_decide.sh && ap decide`
- **SATISFIES**: AC #5, AC #6, AC #9

### UPDATE `autopilot/bin/ap-cycle.sh` — parse the new decision keys, dispatch the three bug acts

- **IMPLEMENT**:
  1. After `:434`, parse `artifact_path="$(json_field "$poll_json" ".artifactPath")"` and `pr_url="$(json_field "$poll_json" ".prUrl")"`.
  2. `act_model` (`:572-579`): `investigate|re-investigate) echo "${AP_INVESTIGATE_MODEL:-opus}"`, `fix) echo "${AP_FIX_MODEL:-sonnet}"`, `review) echo "${AP_REVIEW_MODEL:-sonnet}"`. Extend the existing comment's design-vs-execution reasoning: investigation is the judgment-heavy half (5-Whys synthesis, guard-behaviour reasoning, the adversarial gate) and gets opus, exactly as planning does; fix executes a settled RCA and gets sonnet; review drives delegated debate/triage scripts, where the heavy reasoning happens inside `debate-review`'s own lanes, and gets sonnet.
  3. Lane arms in the action case (`:460-511`): `investigate|re-investigate)` joins the existing `plan|replan)` arm (plan lane, no ports); `fix)` joins the `implement)` arm's lane/slot/port acquisition (build lane, `5173+n`/`8000+n`) but **without** the chained second `run_claude`; `review)` is the new arm from the earlier task.
  4. Dispatch arms in the act case (`:803-850`):
     - `investigate)` → `run_claude "investigate" "/piv-investigate-issue $issue --headless"`
     - `re-investigate)` → same + `--feedback '$feedback_escaped'`, reusing the apostrophe-escaping at `:810`
     - `fix)` → `run_claude "fix" "/piv-implement-issue $issue --headless --rca $artifact_path --ports fe=$fe_port,be=$be_port"`
     - `review)` → `run_claude "review" "/piv-review-pr $pr_url --headless --issue $issue --ports fe=$fe_port,be=$be_port"`
  5. **Widen the `fix)` post-`DONE` write to `fix|build)`, so a later feature fork shares it verbatim rather than duplicating it.** In the `fix|build)` arm, after `run_claude`, on `final_status == DONE` and a valid issue: `queue_set "$issue" --state piv-review-pending --event "<phase> done, PR open -> review pending"` plus `ap-notify.sh "review pending: $issue" "<phase> committed, PR open, agentic review queued"`, selecting the prompt inside the arm by phase (`fix` → `/piv-implement-issue $issue --headless --rca $artifact_path --ports fe=$fe_port,be=$be_port`; a future `build` phase would dispatch `/piv-implement --headless --plan $artifact_path --issue $issue --ports …` the same way). **Wrapper-side, not skill-side**, for the same reason `building → shipping` is (`:820-830`): it must hold even if the fix session dies immediately after its last tool call. **Reasoning to state in this task**: the post-`DONE` write must be provably identical for both kinds, and duplicating these lines across two arms is exactly the drift generator `ap-resume.sh`'s own header GOTCHA (see below) warns about — one arm, shared, is cheaper to keep correct than two arms kept in sync by hand. Add a comment stating explicitly that there is **no chained review dispatch** here, and why (review is 20-60 min of mostly bot-round waiting; pinning a build slot for it is exactly what the separate review lane exists to avoid) — this comment now covers both kinds and is the sentence that keeps a future implement→ship-style chain from ever being added back for either.
- **PATTERN**: `:804-806` (plan), `:809-812` (replan feedback escaping), `:813-833` (implement + wrapper state swap + ping), `:835-844` (standalone ship).
- **IMPORTS**: n/a.
- **GOTCHA**: `run_claude` prepends `--run-dir $AP_RUN_DIR` to `$1` (`:680`). Every new prompt is a single argument and must not itself contain `--run-dir`.
- **GOTCHA**: A phase name must contain no underscore (`ap-runs.py:80-82`). `re-investigate`, not `re_investigate`.
- **GOTCHA**: `ap-cycle.sh` `cd`s to `$WORK_REPO` at `:26` and again at `:801`; skill discovery is cwd-based. The bug-path skills must be discoverable **from the work repo's `.claude/skills/`** — they are symlinked today but not installer-managed (fixed in the Phase 8 task). Do not `cd` a dispatch into a worktree.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-cycle.sh && shellcheck /home/coder/coder-packages/autopilot/bin/ap-cycle.sh`
- **SATISFIES**: AC #7, AC #8

### UPDATE `autopilot/bin/ap-cycle.sh` — reconcile the bug phases

- **IMPLEMENT**:
  1. External-failure requeue map (`:920-924`): add `investigate|re-investigate) requeue_state="queued"`, `fix) requeue_state="piv-draft-review"`, `review) requeue_state="piv-review-pending"`, plus the feature phases a later fork adds to the same map — `design|redesign) requeue_state="queued"`, `build) requeue_state="piv-draft-review"` — so the map is complete before that fork ever dispatches through it. Must match `ap-runs.py`'s `REQUEUE_STATE` exactly — same table, two files, by this repo's duplicate-small-helpers convention; add a cross-reference comment in both, and extend it to say **the two maps must stay identical across `ap-cycle.sh` and `ap-runs.py`, including any phase a later fork adds.**
  2. DONE branch (`:1003-1029`): `if [[ "$final_phase" == "ship" ]]` becomes `ship|review` (the `ready to test` ping with `pr_urls` is right for both). The plan-ready branch (`:1008-1028`) gains `investigate|re-investigate`, with the wording swapped to `RCA ready for review: <issue>` / `RCA auto-approved, piv-implementing: <issue>` and the same `auto_will_build` computation (global `AP_AUTO_APPROVE` or the ticket's own `auto_approve`) so the owner can tell "waiting on you" from "about to fix" at a glance. Message text: `` `ap approve $issue` to fix, `ap reply $issue "..."` = feedback ``.
  3. NEEDS_HUMAN (`:984-1001`) and FAILED (`:862-982`) need **no phase-specific change** — both are already phase-agnostic, and `park_registry_write` records `${final_phase:-}` generically. Verify by reading, and leave a comment noting the confirmation so nobody adds a redundant branch.
  4. **A catch-all fix in the external-failure requeue `case "$final_phase"` itself.** An unmatched `$final_phase` leaves `requeue_state` empty, and the write guard silently skips the queue write entirely — no state change, no diagnostic, on top of whatever the act's own FAILED/NEEDS_HUMAN handling already did. Add a final `*)` arm: on an unmatched phase, write `needs-input` with `question: "unrecognized phase '<phase>' in the external-failure requeue map — routing unknown, needs a human decision"`, rather than silently skipping the write. This predates this plan's own additions but becomes load-bearing the moment a second fork's phases start flowing through the same map — mirror `ap retry`'s existing `REQUEUE_STATE.get(phase)`-miss pattern (fail closed and loud, not silent) rather than inventing a new shape.
- **PATTERN**: `:1005-1007` and `:1008-1028`.
- **GOTCHA**: The FAILED branch's `fail_count` increment applies to bug acts too, including external causes — deliberately, per the comment at `:955-962`. Do not carve out.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-cycle.sh && grep -n 'piv-review-pending\|RCA ready' /home/coder/coder-packages/autopilot/bin/ap-cycle.sh`
- **SATISFIES**: AC #7, AC #9

### UPDATE `autopilot/bin/ap-resume.sh` — review lane and bug phases

- **IMPLEMENT**:
  1. Lane re-acquisition `case "$lane"` (`:302-327`): a `review)` arm looping `1..AP_REVIEW_SLOTS` over `$AP_HOME/lock.review.$n`, identical in shape to `ship)`.
  2. DONE branch (`:421-470`): `if [[ "$phase" == "ship" ]]` → `ship|review`; `plan|replan` → also `investigate|re-investigate` **and, for a later feature fork sharing this branch, `design|redesign`** — same RCA-ready-shaped notify wording generalized to whichever artifact the phase produced. **A new `fix)` arm is required — it is NOT unreachable — and it must be widened to `fix|build)` so a later feature fork's `build` phase shares it rather than duplicating it.** An earlier draft of this task claimed a parked `fix` act "simply reconciles and exits" with no phase-specific handling needed; the plan-critic audit caught that this is wrong. At park time (`ap-cycle.sh`'s NEEDS_HUMAN branch) the ticket's `state` was set to `needs-input`, not left at `piv-implementing`. Per `piv-implement-issue`'s own headless section, the `fix` skill never writes ticket state itself — that write is wrapper-owned, done by `ap-cycle.sh`'s `fix|build)` arm on an ordinary (non-parked) DONE. But a *resumed* fix (or, later, build) act's DONE is reconciled here, in `ap-resume.sh`, not in `ap-cycle.sh` — and without a `fix|build)` arm here, nothing ever writes `piv-review-pending`. The ticket is left at `needs-input` permanently: no decider tier claims `needs-input` without a `feedback` field being set, and `needs-input` is not in `sweep_stale`'s tuple, so there is no backstop either. Add a `fix|build)` arm identical in effect to `ap-cycle.sh`'s own: `queue_set <issue> --state piv-review-pending --event "<phase> done (resumed), PR open -> review pending"` plus the notify ping — mirroring the `investigate|re-investigate` → RCA-ready handling in this same branch. The gap this closes for `fix` applies identically to a later `build`, by exactly the same reasoning; this is why the arm is widened now rather than left as a `fix`-only arm for a follow-up plan to widen later. The `implement)` chained-ship branch (`:431-468`) remains untouched and unreachable for either kind — neither the bug path nor a later feature fork has a chain, so `fix|build)`'s DONE dispatches no second window; the review act is claimed later by an ordinary cycle. That part of the original simplification argument still holds; only the "no arm needed at all" claim was wrong.
  3. NEEDS_HUMAN (`:472-482`) and FAILED (`:484-494`) are already phase-agnostic; verify and comment.
  4. **REQUEUE_STATE / requeue-map cross-reference**: the same feature phases named in the `ap-cycle.sh` reconcile task's requeue map (`design`/`redesign` → `queued`, `build` → `piv-draft-review`) belong alongside this plan's bug rows wherever this script or `ap-runs.py` enumerates them, so the two maps stay identical across both files — extend the existing cross-reference comment to say so.
  5. **A catch-all fix in the DONE branch's own `if/elif` chain — the same gap `ap-cycle.sh`'s reconcile task closes, found by the same audit.** Its `if/elif` chain over `$phase` has no final `else`. An unrecognized phase on a *resumed* act's DONE currently produces silent no-op: no state write, no notify, no window teardown. Add an `else` arm with the same `needs-input` + diagnostic-question treatment as `ap-cycle.sh`'s `*)` arm: `question: "unrecognized phase '<phase>' in ap-resume.sh's DONE branch — routing unknown, needs a human decision"`.
- **PATTERN**: `:319-326` (ship arm), `:424-430` (DONE phase branches).
- **GOTCHA**: `:438` derives a chained-ship window name as `act_build_${acquired_lock_file##*.}_...` — a fragile string trick that happens to work because `lock.build.N` ends in the slot number. It is only reached from the `implement` branch. Do **not** generalize it for review; there is nothing to chain. Do not touch this branch or its window-name trick for any reason — it stays exactly as it is, unreachable for both kinds.
- **GOTCHA**: This script's header (`:25-31`) documents that it deliberately does not replicate the external-failure requeue. That known gap now also applies to the bug phases (and, later, the feature phases sharing the same widened arm); extend the header comment to say so rather than silently widening it.
- **GOTCHA**: Caught by the plan-critic audit: `ap-resume.sh`'s DONE branch is a **second, independent reconciliation implementation** from `ap-cycle.sh`'s — the two do not share code. Every phase this plan adds must be reconciled identically in both files, or a parked-then-resumed act silently strands its ticket exactly as the missing `fix)` arm above did. Treat this as a standing invariant to re-check whenever either file's phase list changes in the future, not just for this plan — this is precisely why the `fix)` arm above is widened to `fix|build)` now rather than left for a follow-up plan to discover missing a second time.
- **GOTCHA**: `run_claude` prepends `--run-dir $AP_RUN_DIR` to its prompt argument; every new prompt is a single argument and must not contain `--run-dir` itself.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-resume.sh && shellcheck /home/coder/coder-packages/autopilot/bin/ap-resume.sh`
- **SATISFIES**: AC #7

### ADD `claude/skills/piv-commit/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: The smallest of the seven. Contents:
  1. The pointer sentence.
  2. **No ask points exist** in this skill's 33-line procedure — state it plainly, so a reader does not go looking for a mapping table that would be empty.
  3. **This skill is never dispatched as its own act.** It runs inside the build-phase act — `fix` for a bug (invoked by `piv-implement-issue`), `build` for a feature (invoked by `piv-implement`, once that fork ships) — and inherits that session's ENG id and worktree either way. It therefore writes **no** `status.json` of its own — the enclosing act writes one for the whole phase.
  4. **Capture the commit SHA**: immediately after the commit succeeds, run `git rev-parse HEAD` and hand the short SHA back to the caller for `status.json`'s `detail` and the ticket's `history`. Today the skill prints prose summaries only, so the SHA is unrecoverable by the next phase — and it is what `babysit-pr`'s replies cite ("Confirmed and fixed in `a1b2c3d`", `babysit-pr/SKILL.md:204`).
  5. **On any git failure** (nothing staged, a pre-commit hook rejection, a lock file): do not retry, do not amend, do not `git reset`. Report the exact failing command and stderr to the caller, which writes `FAILED` with that text in `detail`. `Bash(git reset --hard *)` is on the profile's **deny** list — never attempt a recovery through it.
  6. **The commit must include** the implementation, its tests, the approved artifact (the RCA or the plan) if this is the first commit on the branch, and the phase's report. Nothing else: an out-of-plan file in the commit becomes an out-of-scope finding in the very next phase's review.
  7. **`.claude/` AI-layer summary** (`:30-33`): still printed when applicable, as prose to the caller; nothing extra headlessly.
- **PATTERN**: `ship-work/SKILL.md:392-402` — the shortest existing headless opener, including its "the only thing headless mode changes is how a stop or a success gets reported" framing.
- **GOTCHA**: Do not add a queue write here. Two skills writing the same ticket inside one act is how a `history` trail becomes unreadable; the enclosing phase owns the write.
- **GOTCHA — verified kind-agnostic already**: sub-items 1, 2, 4, 5, 7 above and both GOTCHAs need no fork-specific wording — only sub-items 3 and 6 baked in the bug fork, and both are now generalized above.
- **VALIDATE**: `grep -n 'Headless mode\|rev-parse' /home/coder/coder-packages/claude/skills/piv-commit/SKILL.md`
- **SATISFIES**: AC #15

### ADD `claude/skills/piv-create-pr/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**:
  1. The pointer sentence.
  2. **Never its own act** — runs inside the `fix` act, same inheritance and no-`status.json` rule as `piv-commit`.
  3. **Precondition mapping** (`:42-48`) — all five are deterministic fail-fast checks, not human-judgment asks, so **none** becomes `NEEDS_HUMAN`:

     | precondition | headless resolution |
     |---|---|
     | On `{base}` | `FAILED`, `detail: "on base branch; the fix act's worktree mandate was not honoured"` |
     | Uncommitted changes | `FAILED`, `detail` = the `git status --short` output |
     | No commits ahead of `{base}` | `FAILED`, `detail: "nothing to PR"` |
     | Existing PR already open for this branch | **`DONE`-idempotent**: print and return the URL as a success, not a failure — this is the normal state on a retried `fix` act |
     | Clean, ahead, no PR | proceed |

  4. **Push with the explicit branch name.** `git push -u origin HEAD` as written at `:66` would actually **pass** under the current profile via the pre-existing `Bash(git -C *)` allowance (e.g. `git -C <worktree> push -u origin HEAD` matches) — the plan-critic audit caught that the plan originally mis-stated this as a permission denial. It is still the wrong thing to do, on its own terms: pushing `HEAD` rather than the explicit branch name loses the branch-naming discipline every other worktree in this repo follows, makes retries harder to reason about (which branch did a prior attempt actually push?), and produces a remote branch name a human reading `git branch -a` can't correlate to the ticket at a glance. Push the **explicit branch name the act's worktree is already on**: `haroun/eng-<id>-fix-<slug>` for a bug, `haroun/eng-<id>-<slug>` for a feature (once that fork ships). So: `git -C <worktree> push -u origin haroun/eng-<id>-fix-<slug>` for this fork — enforced by convention in this skill's prose, not by the permission profile.
  5. **Opening the PR**: `gh pr create` genuinely **is not** on the allow list today, and unlike `git` there is no `Bash(gh -C *)`-style escape hatch already granted for `gh` — confirmed by the plan-critic audit reading the profile directly. Either use the already-allowed `mcp__github__create_pull_request`, or rely on Phase 8 adding `Bash(gh pr create *)`. State the preference: prefer the **MCP tool**, per the protocol's own "prefer the allowed GitHub MCP tools over `gh` when one fits" rule, which also sidesteps the heredoc-in-a-compound-command shape at `:70-89` that the no-pipes/no-compound rule makes fragile.
  6. **Body content**: unchanged from `:70-89`, plus a **kind-branched implementation-report lookup** — this is exactly what `:57-59`'s `Implementation report (if piv-implement-issue wrote one — .claude/reports/<…>-report.md)` lookup must become once a feature fork exists alongside this one:

     | ticket kind | report path folded into the PR body | approved artifact linked under `## Linked` |
     |---|---|---|
     | bug | `docs/issues/reports/<ENG-ID>-fix-report.md` | the RCA, `docs/issues/issue-<ENG-ID>.md` |
     | feature | `docs/plans/reports/<ENG-ID>-<slug>-report.md` | the plan, `docs/plans/<ENG-ID>-<slug>.md` |

     Both are resolvable the same deterministic way — anchored on the ENG id at a fixed relative path — and **both are committed by `/piv-commit` inside the same act**, so the lookup never races an unwritten file. `<slug>` is the plan file's own slug, so the report name is derivable from the plan path with a suffix, not from a second convention. Keep `Part of ENG-<id>` never `Fixes`/`Closes`/`Resolves` for both.
  7. **Multi-repo** (`:26-32`): unchanged headlessly — one PR per touched repo, cross-linked, merge order stated. Every URL goes into the act's `pr_urls`.
  8. **Output**: return PR number + URL + base←head to the caller. Do **not** print the interactive "run `piv-review-pr`" handoff as an instruction — the orchestrator dispatches that as its own act from the `piv-review-pending` state.
- **PATTERN**: `ship-work/SKILL.md:404-411` — the "pushing feature branches and opening PRs **is** pre-approved under `--headless`, and nothing else loosens" framing. Restate the same limits: never `main`, never a direct push to `dev`, never a merge call.
- **GOTCHA**: `git symbolic-ref` / `git remote show` (base detection, `:16-17`) already pass today via the `Bash(git -C *)` allowance — use `git -C <worktree> symbolic-ref ...` / `git -C <worktree> remote show ...`. As a belt-and-suspenders default, hard-code this project's own rule too (`dev` for root/`backend/`/`frontend/`, `main` for `assistants/`/`observability/`, per `:20-22`) and use the git calls only to confirm it.
- **GOTCHA**: `docs/plans/` **is tracked** in the work repo (verified: ~60 committed files) so it exists in any fresh worktree — unlike `docs/issues/`, which this document correctly flags as needing creation for the bug path. `docs/plans/reports/` is new and does not exist in HEAD, for whichever fork writes to it first: create it before writing, same as this document's `docs/issues/` note.
- **GOTCHA — verified kind-agnostic already**: sub-items 1, 2, 3 (the five-row precondition table), 5, 7, 8 above and both original GOTCHAs need no fork-specific wording — only sub-items 4 and 6 baked in the bug fork, and both are now generalized above. In particular the `Existing PR already open → DONE-idempotent` row is what makes a retried `build` act safe, exactly as it makes a retried `fix` act safe.
- **VALIDATE**: `grep -n 'Headless mode\|haroun/eng-\|DONE-idempotent\|docs/plans/reports\|kind-branched' /home/coder/coder-packages/claude/skills/piv-create-pr/SKILL.md`
- **SATISFIES**: AC #15, AC #16

### ADD `claude/skills/piv-review-pr/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: The largest of the seven, because it owns the `babysit-pr` loop.
  1. The pointer sentence.
  2. **Phase**: `review`. `phase_at_question: "review"`. Invoked as `/piv-review-pr <pr-url> --headless --issue ENG-<id> --run-dir <d> --ports fe=..,be=..`. **`--issue` is a headless-only token** and is required: this skill's own arguments carry a PR, not a ticket, and every queue write needs the ENG id. It is the only new flag this feature introduces on any skill.
  3. **Preflight, before anything else** — fail fast rather than mid-round: `command -v gh` + `gh auth status`, `command -v jq` (a **hard** dependency of `babysit-pr/scripts/threads.sh`, declared at `babysit-pr/SKILL.md:5`), `command -v node` (required by `debate-review/scripts/review-pr.mjs`). Any missing → `FAILED`, `detail` naming the missing tool. A cron-launched act's `PATH` inheritance is not guaranteed even though all three resolve for an interactive shell here.
  4. **Work in the ticket's worktree**: resolve it via `git worktree list | grep "wt-eng<id>-"`, `cd` there before `gh pr checkout`. `threads.sh` picks the forge from the cwd's git origin (`babysit-pr/SKILL.md:22-25`), so the cwd is load-bearing, not incidental.
  5. **State guard** (`:32`): `MERGED`/`CLOSED` → **`DONE`**, `detail: "PR already <state>; nothing to review"`, and swap the ticket to `ready-to-test` — a merged PR is not a failure. `DRAFT` → proceed. An already-reviewed head sha (`debate-review` exit code 3, `:62`) → do **not** `--force`; proceed straight to the `babysit-pr` rounds using the existing review.
  6. **Phase 3 validation** (`:44-46`) with `--ports`: bind exactly the two given ports if the suite needs a server; teardown before any terminal write.
  7. **`babysit-pr` under headless** — the mapping table, this section's real payload:

     | `babysit-pr` behavior | headless resolution |
     |---|---|
     | Blockers (`:132-146`) | unchanged and fully autonomous: verify, reproduce where practical, fix, run the gate, one consolidated push per round, reply in-thread, resolve. Already needs no human. |
     | Reviewer silence / rate-limit (`:265-268`) | unchanged: mark the reviewer unavailable, do not wait out a cooldown, disclose the gap. Never report an unreviewed head as clean. |
     | **Non-blockers: one batched ask per round (`:222-238`)** — the one genuine design call | **auto-apply the skill's own stated recommendation per item**, with one carve-out. "fix now" → apply it in the round's consolidated push. "open an issue" → file it (allowed via `mcp__github__issue_write`) and reply with the link. "reject" → reply with the evidence and resolve. **Carve-out:** a "fix now" whose change would touch a file **outside this PR's diff** is *not* auto-applied — record it as a deferred note instead. Reasoning, stated in the section: (a) the recommendation is authored by the same verification pass that classified the finding non-blocking, so applying it is the protocol's *documented default* branch, not an invention; (b) a non-blocker by definition ships nothing broken, and every applied change is visible in the diff the human reads before merging — a bounded, reviewable failure mode; (c) parking the whole act on a nitpick would spend the pipeline's scarcest resource (the owner's attention) on its cheapest findings, exactly inverted; and (d) the carve-out is what keeps it safe — out-of-diff edits are scope creep past the fix's blast radius, which is precisely what the batched ask was really protecting against. Every auto-applied item and every deferral is recorded in the ticket's `history` and in `detail`, so the choice is reversible. |
     | Budget boundary — 2 repair pushes + 2 re-review cycles (`:240-243`, `:279-280`) | **`NEEDS_HUMAN`**. The hand-off payload maps directly: `question` = remaining findings + unresolved thread count + last-reviewed sha + unavailable reviewers. Never describe an unreviewed head as clean. |
     | Every "stop and speak up" item (`:310-322`) | **`NEEDS_HUMAN`**, one per trigger, no invention needed: an out-of-scope-demanding finding; two bots unresolvably contradicting; a finding recurring after one re-verified retry; **any human reviewer comment, always**; CI failing for infrastructure reasons; budget exhausted. |
     | "Ask the user whether to merge" (`:305-308`) | **the terminal, permanently.** Never simulate, never merge, never approve. Under headless: stop here and write the success end state below. |
     | Attribution (`:190-198`) | unchanged: `gh api user -q '.name // .login'` once per session, and sign the model name. |
     | Harvest-count discipline (`:66-76`) | unchanged and important: print the unfiltered totals before any filter; a filter eliminating 100% of items is presumed broken. |
     | **Branch pushed to by someone other than this act, mid-round** (gap identified by Codex's independent second draft, Phase 5c) | `NEEDS_HUMAN`. Before each repair push, check the branch's remote head against the SHA this act last pushed; a mismatch means a human (or another process) pushed to it. Never treat that push as, count it against, or silently rebase over — the repair-push budget and the round loop both assume every push during review originates from this act, and that assumption breaks the moment a human is also touching the branch. |

  8. **Success end state**: rounds worked to the budget or to a clean merge-gate round, nothing unresolved that this act can close. One write:
     ```bash
     python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state ready-to-test \
       --field pr_urls='["<url>", ...]' \
       --event "review rounds worked, awaiting your merge decision"
     ```
     Linear: add label `agent:ready-to-test`; state stays `In Progress`; **never** `Staging` or `Done`; never a comment. Then `status.json` with `status: DONE`, `phase: "review"`, `pr_urls` filled, `detail` = rounds run + blockers fixed with SHAs + findings rejected + issues filed + unresolved-thread count + CI state. Leave the kata ref **open** at `work.attention ok` — this phase never merges, so it never performs post-merge closeout. Same emphatic note as `ship-work/SKILL.md:444-447`: without this write the ticket never leaves `piv-reviewing`.
  9. **This is where the new pipeline rejoins `ap`'s never-merges invariant** — say it explicitly, and say why it is structural rather than a policy: `piv-review-pr:17-19` and `babysit-pr:305-306` both refuse on their own terms, and `mcp__github__merge_pull_request` is on the profile's **deny** list.
- **PATTERN**: `ship-work/SKILL.md:413-456` — hard-stops→`NEEDS_HUMAN` with the evidence quoted, then a single-write success end state with the Linear label and the "do not skip this write" warning.
- **GOTCHA**: `debate-review` takes 10-20 minutes and `:60-62` says to background it. Under headless, backgrounding across a turn boundary is fatal (the protocol's background rule). Run it as a **blocking foreground** command; if it cannot finish in-turn, write an interim `FAILED` first.
- **GOTCHA**: `babysit-pr` pushes repair commits. Same `haroun/*` push-permission constraint as `piv-create-pr`; `git push --force-with-lease` is allowed, raw `--force` is denied.
- **GOTCHA**: `:36-42`'s "implementation report at `.claude/reports/*{branch}*`" lookup should point at a **`kind`-branched** path, so the documented-deviation cross-check actually finds something for either fork:

  | ticket kind | implementation report to cross-check |
  |---|---|
  | bug | `docs/issues/reports/<ENG-ID>-fix-report.md` |
  | feature | `docs/plans/reports/<ENG-ID>-<slug>-report.md` |

  **Everything else in this section — the phase, the required `--issue` token, the preflight, the worktree resolution, the state guard, the `--ports` rule, the entire `babysit-pr` mapping table including the non-blocker auto-apply carve-out and the human-pushed-branch stop, the success end state, and the never-merges statement — is verified already kind-agnostic; no change needed.** Said explicitly here so a future reader knows it was checked rather than skipped.
- **VALIDATE**: `grep -n 'Headless mode\|--issue\|ready-to-test\|never merge\|kind-branched\|already kind-agnostic' /home/coder/coder-packages/claude/skills/piv-review-pr/SKILL.md`
- **SATISFIES**: AC #15, AC #17, AC #18

### ADD `claude/skills/red-team/SKILL.md` and `claude/skills/challenge/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: One short section each, near-identical:
  1. The pointer sentence.
  2. **You are never dispatched as a headless act.** You run as a sub-agent inside one (today: `piv-investigate-issue`'s step 7, and `implement-issue`'s step 7b for red-team). You write **no** `status.json` and **no** queue entry — you return your report to the caller, which owns both.
  3. **Never ask.** There is nobody to ask. Where the rubric would ask for data, take the documented default: **report the gap as a finding**.
  4. **Data access is usually restricted.** The `dontAsk` profile is path-scoped and allows no database read tools and no piped commands. So: red-team's §3 replay (`:79-91`) and challenge's §1 ledger spot-check / §4 positive control (`:34-57`, `:99-113`) will frequently be unobtainable. When they are, say **"could not obtain the rows"** and treat that as the finding — never reason around the missing replay and never present an un-run replay as a passed one. This is the same rule `implement-issue/SKILL.md:388-390` already applies to red-team's replay.
  5. **Never write to the repo, never push, never post to Linear or a PR.** Your output is prose returned to the caller; the caller decides where it lands (for the bug path: the RCA's `## Adversarial review` section).
  6. **Verdict wording is load-bearing** — the caller branches on it mechanically. Use exactly the rubric's own vocabulary: red-team `ship` / `ship with the named additions` / `do not ship as specified` (`:159`); challenge `stands` / `stands with caveats` / `does not survive` (`:154`). A near-miss phrasing is unroutable.
  7. **A critic finding nothing is a real result** — record what was checked (both rubrics already say this: `challenge:146`, `red-team:157-165`). Do not manufacture a finding to look useful.
- **PATTERN**: the pointer opener; and `challenge:146` / `red-team:157-165` for the honest-null-result framing.
- **GOTCHA**: These two files are also used interactively and by other callers. Keep the section purely additive and short — nothing above changes their rubrics.
- **GOTCHA**: `red-team` and `challenge` are symlinked into the work repo but appear as `??` in its `git status` (verified). Phase 8's installer task fixes that; without it they are also unmanaged by `--check`.
- **VALIDATE**: `grep -c 'Headless mode' /home/coder/coder-packages/claude/skills/red-team/SKILL.md /home/coder/coder-packages/claude/skills/challenge/SKILL.md`
- **SATISFIES**: AC #15, AC #14

### UPDATE `autopilot/settings/autopilot.json` — extend the `dontAsk` allow list

- **IMPLEMENT**: Add, each justified by the exact call site that needs it:
  - `Bash(gh pr create *)`, `Bash(gh pr list *)`, `Bash(gh pr diff *)`, `Bash(gh pr checkout *)`, `Bash(gh pr comment *)` — `piv-create-pr` Phase 3, `piv-review-pr` Phase 1, `babysit-pr`'s `@codex review` mention
  - `Bash(node *)` — `debate-review/scripts/review-pr.mjs`, `codex-delegate/scripts/relay.mjs`
  - `Bash(/home/coder/coder-packages/claude/skills/babysit-pr/scripts/threads.sh *)` — the thread harvester, allowed by its absolute path rather than a `*threads.sh*` wildcard, so the grant names one known script
  - `mcp__github__pull_request_review_write`, `mcp__github__add_comment_to_pending_review`, `mcp__github__add_reply_to_pull_request_comment` — `babysit-pr`'s in-thread replies, as MCP alternatives to `gh api`
- **IMPLEMENT**: Verify the **deny** list still covers everything it must and add nothing that weakens it. Confirm `mcp__github__merge_pull_request` stays denied, and that `mcp__linear-server__save_comment` stays **absent** from allow (the structural enforcement of "headless never comments on Linear").
- **PATTERN**: `autopilot/settings/autopilot.json:4-60` — narrow, verb-scoped prefixes; the file's own README note (`README.md:282-289`) says to extend **after** seeing a denial rather than pre-approving broadly. This task deliberately front-runs that for calls whose denial is already provable by reading the skills, and nothing more.
- **GOTCHA**: `Bash(git push -u origin haroun/*)` is left **unchanged**. Widening it is the wrong fix; the branch-naming mandate in the skills is the right one.
- **GOTCHA**: The plan-critic audit found that `Bash(git -C *)` (`autopilot/settings/autopilot.json:19`) is **already** on the allow list — so `git -C <path> checkout/switch/rev-parse/symbolic-ref/remote show/blame/show/stash push/stash pop` all already pass today, and an earlier draft of this task wrongly proposed adding bare (non-`-C`) forms of each. Those additions are deliberately **not** in the list above — they'd be redundant. `gh` has no equivalent escape hatch (no `Bash(gh -C *)` is granted), which is why the `gh pr *` grants above are genuinely needed.
- **GOTCHA**: A piped or compound Bash command is denied unless **every** segment is allowed. `Bash(node *)` does not rescue `node script.mjs | tee log`.
- **VALIDATE**: `python3 -c "import json; d=json.load(open('/home/coder/coder-packages/autopilot/settings/autopilot.json')); a=d['permissions']['allow']; print(len(a)); print([x for x in a if 'gh pr' in x or 'node' in x]); assert 'mcp__github__merge_pull_request' in d['permissions']['deny']"`
- **SATISFIES**: AC #16, AC #19

### UPDATE `scripts/install-autopilot.sh` — manage every bug-path skill

- **IMPLEMENT**: `SKILL_NAMES` (`:281`) gains `piv-investigate-issue`, `piv-implement-issue`, `piv-commit`, `piv-create-pr`, `piv-review-pr`, `babysit-pr`, `debate-review`, `red-team`, `challenge`, `codex-delegate`, `piv-validate`, `worktree-create` — every skill the bug path invokes, directly or transitively. `EXCLUDE_BODY` (`:328-334`) gains **all** of them plus `test-issue` (a pre-existing omission) and `headless-protocol.md`.
- **IMPLEMENT**: The `## A note on coder-packages/claude/skills/` README section (`:320-338`) gains the new names.
- **PATTERN**: `install-autopilot.sh:286-323` — the loop already handles symlink convergence, `skip-worktree` for tracked paths, and `--check`; only the two lists change.
- **GOTCHA**: The `piv-*` symlinks already exist in the work repo (created by hand, dated Aug 24) and are excluded via **separate, unmanaged** blocks in `.git/info/exclude`. Adding them to `EXCLUDE_BODY` duplicates those lines — harmless to git. **Do not** remove the hand-rolled blocks in this pass, despite an earlier draft of this task suggesting it: the plan-critic audit found that several currently-symlinked skills — `worktree-create`, `prime-*`, `plan-*`, `piv-slice-epic`, `piv-review-changes`, `piv-fix-review-findings`, `piv-implement`, `piv-plan-implementation`, `claude-delegate`, `delegate-setup`, `browser-verify-chrome` — are covered by those other hand-rolled blocks but are **not** in this task's `SKILL_NAMES` list. Removing their blocks without also adding all of them to `SKILL_NAMES`/`EXCLUDE_BODY` would surface every one as `??`, breaking the VALIDATE below. That consolidation is real cleanup but is out of scope for this plan — leave every hand-rolled block except the one this task's own additions duplicate.
- **GOTCHA**: `red-team` and `challenge` are currently in **neither** block — `git -C /home/coder/root-for-local status --porcelain .claude/skills` prints them as `??`. Left alone, they show up as untracked in the main checkout, which is one more contributor to the dirty-tree traps this plan works around.
- **GOTCHA (plan-critic audit)**: the live managed exclude block also currently contains `.claude/skills/autopilot-poll`, which this task's `EXCLUDE_BODY` list omits. `ensure_managed_block` replaces the managed block **wholesale** when it differs from what's expected, so applying this task as originally written would silently drop that line. `.claude/skills/autopilot-poll` is a **dangling symlink** in the work repo today (its target no longer exists anywhere in `coder-packages`) — deleting it is the cleaner fix (a stale exclude entry for a nonexistent target has no value), but confirm nothing still references it before removing it; if for some reason it needs to stay, add it to `EXCLUDE_BODY` explicitly instead. Either way, verify with `git -C /home/coder/root-for-local status --porcelain .claude/skills/autopilot-poll` before and after this task.
- **VALIDATE**: `cd /home/coder/coder-packages && ./scripts/install-autopilot.sh && ./scripts/install-autopilot.sh --check && git -C /home/coder/root-for-local status --porcelain .claude/skills` (expect: empty)
- **SATISFIES**: AC #19

### UPDATE `claude/skills/daily-brief/SKILL.md` — the new states

- **IMPLEMENT**: Sections mirroring the existing ones: **Awaiting your RCA review** (`state: piv-draft-review`, `ap approve` prompt, auto-approve noted), **Piv-drafting** (`piv-drafting`), **Piv-implementing** (`piv-implementing`), **Review pending** (`piv-review-pending`, PR open + review queued), **Piv-reviewing** (`piv-reviewing`, rounds in flight). Note in the input contract (`:31`) that a queue entry now carries `kind`, and prefix a bug ticket's line with `[bug]` so the digest distinguishes the forks at a glance.
- **PATTERN**: `daily-brief/SKILL.md:64-102` — one section per state, one line per ticket, `eng_id` + note.
- **GOTCHA**: Beyond the brief's stated file list — small and doc-only, but without it a bug ticket sitting at `piv-draft-review` is invisible in the 07:00 digest, which is the main "what needs me today" surface. **GOTCHA specific to this rename**: the bold section titles here are the exact capitalized forms of the old state tokens (`**Investigating**`, `**Fixing**`, `**Reviewing**`) and the Level-2 VALIDATE grep is lowercase-only, so it would not have flagged these on its own — renamed to `**Piv-drafting**`/`**Piv-implementing**`/`**Piv-reviewing**` by hand, matching the new shared state names.
- **VALIDATE**: `grep -n 'piv-draft-review\|piv-review-pending\|\[bug\]' /home/coder/coder-packages/claude/skills/daily-brief/SKILL.md`
- **SATISFIES**: AC #10

### UPDATE `autopilot/tests/test_decide.sh` — new tier cases

- **IMPLEMENT**: New cases, each a `setup_case` + `seed_ticket` + `run_decide --claim` + asserts on the decision JSON and the resulting on-disk state:
  1. `queued` + `kind=bug` → `action: investigate`, state `piv-drafting`.
  2. `queued` with **no `kind` key at all** → `action: plan`, state `planning` (back-compat, the single most important case here).
  3. `piv-draft-review` + `pending_approval` + a resolvable RCA fixture → `action: fix`, `artifactPath` set, state `piv-implementing`.
  4. `piv-draft-review` + `feedback` → `action: re-investigate`, feedback relayed, state `piv-drafting`, `feedback` cleared.
  5. `piv-draft-review` + `feedback` + `pending_approval` → feedback **wins** (mirrors the existing plan-review precedence case).
  6. `piv-draft-review` + approval, RCA path unresolvable → `needs-input`, `phase_at_question: "investigate"`, scan continues.
  7. `piv-review-pending` + `pr_urls` non-empty + review lane free → `action: review`, `prUrl` set, state `piv-reviewing`.
  8. `piv-review-pending` + empty `pr_urls` → `needs-input`, `phase_at_question: "review"`.
  9. `--busy review` + a `piv-review-pending` ticket **and** a `ship-pending` ticket → the ship is claimed, the review is not (per-entry lane check, no cross-lane starvation).
  10. A `plan-review` and an older-`seq` `piv-draft-review` both approved, build lane free → the **older seq** wins (FIFO fairness across forks).
  11. `needs-input` + `feedback` + `phase_at_question: "fix"` → `action: re-investigate`.
  12. `needs-input` + `feedback` + `phase_at_question: "review"` → **no action** (mirrors the existing `ship` skip).
  13. `piv-drafting`/`piv-implementing`/`piv-reviewing` with no ledger row in 3h and no lock held → swept to `failed`.
  14. Every legacy case still passes unchanged.
- **PATTERN**: `test_decide.sh:105-110` onward; `seed_ticket` already JSON-decodes extra fields, so `kind=bug` and `pr_urls='["https://x/1"]'` work as-is. Add a `seed_rca_file` helper mirroring `test_cycle.sh:85-91`'s `seed_plan_file`.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_decide.sh`
- **SATISFIES**: AC #12

### UPDATE `autopilot/tests/test_cycle.sh` — stub + new cycle cases

- **IMPLEMENT**:
  1. **Stub first**: the `claude` stub's phase detection (`:114-121`) must learn the bug prompts — `*piv-investigate-issue*` → `investigate` (→ `re-investigate` when `--feedback` is present), `*piv-implement-issue*` → `fix`, `*piv-review-pr*` → `review`. Add `AP_TEST_FIX_STATUS`/`AP_TEST_REVIEW_STATUS`/`AP_TEST_INVESTIGATE_STATUS` knobs and the matching `AP_TEST_SKIP_STATUS_*`/`AP_TEST_EXIT_CODE_*` variables to `AP_TEST_VARS` (`:291-299`). Extend `setup_case`'s `unset` line (`:307`) with `AP_REVIEW_SLOTS`. **GOTCHA (plan-critic audit)**: the stub has an existing `[[ "$prompt" == *--feedback* ]] && phase="replan"` override that runs **after** the phase-detection case statement and unconditionally wins. Order the new `re-investigate` detection so this pre-existing override doesn't clobber it back to `replan` for a bug-path `--feedback` prompt — the override needs to become fork-aware (branch to `re-investigate` when the prompt also matches `*piv-investigate-issue*`, `replan` otherwise), not just left as a blanket rule that fires last.
  2. New cases:
     - `queued` + `kind=bug` → exactly one claude call, prompt contains `/piv-investigate-issue ENG-x --headless` and `--run-dir`, ticket at `piv-drafting`, cwd is the work repo.
     - Same with `AP_TEST_ACT_STATUS=DONE` → the wrapper's DONE branch pings `RCA ready for review`; assert the **notify** text, matching how the existing plan-DONE cases assert (the stub does not write queue state).
     - `piv-draft-review` + approved → prompt contains `/piv-implement-issue`, `--rca`, and `--ports fe=5174,be=8001` for build slot 1.
     - The same, with build slot 1 held → slot 2's ports `fe=5175,be=8002`.
     - `fix` DONE → **exactly one** claude call this cycle (no chained review!), ticket at `piv-review-pending`, notify says `review pending`.
     - `piv-review-pending` → prompt contains `/piv-review-pr <url> --headless --issue ENG-x` and `--ports fe=5188,be=8021` for review slot 1.
     - Every review slot held + a `piv-review-pending` ticket → no claude call for it, ticket untouched, but a free ship lane still ships a `ship-pending` ticket in a later cycle.
     - `NEEDS_HUMAN` at each of `investigate`/`fix`/`review` → `needs-input` + the right `phase_at_question` + the notify + (persistent mode) a parked-registry entry.
     - `FAILED` with an external signature at each bug phase → requeued to `queued`/`piv-draft-review`/`piv-review-pending` respectively, `history` names the matched line, `fail_count` still incremented.
     - `FAILED` with no external signature at a bug phase → terminal `failed` with a real reason in `history`.
     - **Port-collision assertion**: extend the existing "no slot is ever assigned the human's baseline" case (`:1165-1185`) to also assert the review lane's ports never collide with any build or ship slot's, for max slot counts of both.
     - `AP_REVIEW_SLOTS` clamping: `99` → 4, `0` → 1, `abc` → 2.
     - Persistent mode: a review act's window is named `act_review_1_ENG-x_review` and `ap-runs.py`'s `_ACT_WINDOW_RE` matches it.
     - **Parked-and-resumed `fix` act (plan-critic audit case)**: persistent mode, a `fix` act parks to `needs-input` (NEEDS_HUMAN), then `ap-resume.sh` resumes it to `AP_TEST_ACT_STATUS=DONE` — assert the ticket ends at `piv-review-pending` (via `ap-resume.sh`'s new `fix)` arm), not stranded at `needs-input`. This is the regression test for the gap the audit found: `ap-resume.sh`'s DONE branch previously had no `fix)` arm at all.
- **PATTERN**: `test_cycle.sh:1103-1185` (build slot cases, including the port assertions) and `:868-940` (lane-held cases).
- **GOTCHA**: `run_case` defaults `AP_ACT_LAUNCH_MODE=oneshot` (`:327`) deliberately, so most new cases need no tmux. Only the window-name case sets `persistent` plus its own isolated `AP_TMUX_SESSION`.
- **GOTCHA**: `hold_lane_lock` (`:343-355`) must not be called via `$(...)` — the comment explains the sandbox reaps the subshell's background job. Copy the call convention exactly.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_cycle.sh`
- **SATISFIES**: AC #12

### UPDATE `autopilot/tests/test_install_skills.sh` — the expanded managed set

- **IMPLEMENT**: Assert that every name added to `SKILL_NAMES` is symlinked and present in the exclude block, and that `--check` reports converged afterward.
- **PATTERN**: the file's existing assertions over `SKILL_NAMES`.
- **GOTCHA (plan-critic audit)**: this test file has its **own** hard-coded `SKILL_NAMES` list, separate from `scripts/install-autopilot.sh`'s — it does not read the installer's list at runtime. Extend this file's own list by hand to match every name added to the installer's `SKILL_NAMES` in the earlier task; forgetting this makes the test assert against a stale, smaller set while the real installer converges correctly, silently losing coverage.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_install_skills.sh`
- **SATISFIES**: AC #12, AC #19

---

## TESTING STRATEGY

The orchestrator half of this change is genuinely well covered by existing harnesses (a 1653-line `test_cycle.sh`, a 453-line `test_decide.sh`) that stub `claude`/`tmux`/`ap-notify.sh` on `PATH` and seed queue fixtures directly. The skill half is executable prose with no compiler — it is validated by one supervised live run, not by unit tests, and that asymmetry should be stated rather than papered over.

### Unit Tests

- **`test_queue.sh` (new)**: `kind` default/validation/back-compat, `artifact_path` presence, `list_queue`'s string-vs-iterable forms and its seq ordering.
- **`test_decide.sh` (extended)**: 14 new cases covering every new tier branch, the `kind` intake fork, cross-fork FIFO fairness, per-entry lane checks, unresolved-artifact and unresolved-PR routing, tier-3 phase routing, and the extended stale sweep. Fixtures are JSON files on disk — no network, no `gh`, no model.
- Follow the existing approach exactly: `mktemp -d` per case, `seed_ticket` via `ap_queue.new_ticket` so `seq` is assigned the real way, one `assert` per distinct claim, `ALL PASS`/`N FAILURE(S)` exit contract.

### Integration Tests

- **`test_cycle.sh` (extended)**: the full decide→act→reconcile path for all three bug phases with a stubbed `claude`. Asserts on **recorded claude argv** (the prompt is the contract between wrapper and skill — an argv assertion is the only way a prompt-text regression gets caught), the resulting ticket state and `history`, the ledger row's phase/status/model, the notify text, port assignment per slot, and lane-exhaustion behavior.
- **`test_install_skills.sh` (extended)**: symlink + exclude-block convergence for the expanded set.
- Not covered by any harness, deliberately: real `tmux` injection semantics (`test_cycle.sh:195-200` records that these were verified live rather than re-tested), and anything requiring a real `claude`, `gh`, or GitHub.

### Edge Cases

- A ticket file with **no `kind` key** (every ticket on disk today) → the feature path. The single highest-value regression test here.
- A `bug` ticket whose RCA cannot be resolved (worktree swept, file renamed) → `needs-input`, not a crash and not a silent stall.
- A `piv-review-pending` ticket with empty `pr_urls` → `needs-input`.
- Two bug tickets both approved with only one build slot → one claimed, one left, no double-claim (`lock.issue.<id>` enforced).
- A bug ticket and a feature ticket both approved → the older `seq` wins; neither fork starves.
- Review lane exhausted while the ship lane is free → the ship still runs.
- A crashed bug act (no `status.json`) → `FAILED` per phase, then the 3h stale sweep as the backstop.
- A retried `fix` act on a branch that already carries the fix → skips to `piv-create-pr`, which finds the open PR and returns `DONE`-idempotent. **No double implementation, no duplicate PR.**
- `jq` or `node` absent from a cron-launched act's `PATH` → review preflight `FAILED` with a named tool, not a mid-round mystery.
- `ap down` with a review act in flight → refused (and `--force` still overrides).
- **Rollback with a bug ticket mid-flight**: reverting the code leaves the ticket in a state no tier claims *and* no sweep sweeps. Recovery is `ap sessions` → `[s]` → set a state by hand. Note this in the rollback plan; do not discover it live.

---

## VALIDATION COMMANDS

Execute every command to ensure zero regressions and 100% feature correctness.

### Level 1: Syntax & Style

```bash
cd /home/coder/coder-packages
shellcheck autopilot/bin/ap autopilot/bin/ap-cycle.sh autopilot/bin/ap-env.sh \
           autopilot/bin/ap-decide.sh autopilot/bin/ap-resume.sh \
           scripts/install-autopilot.sh autopilot/tests/*.sh
bash -n autopilot/bin/ap-cycle.sh && bash -n autopilot/bin/ap-resume.sh && bash -n autopilot/bin/ap
python3 -m py_compile autopilot/bin/ap_queue.py autopilot/bin/ap-decide.py autopilot/bin/ap-runs.py
python3 -c "import json; json.load(open('autopilot/settings/autopilot.json'))"
```

### Level 2: Unit Tests

```bash
bash /home/coder/coder-packages/autopilot/tests/test_queue.sh
bash /home/coder/coder-packages/autopilot/tests/test_decide.sh
```

### Level 3: Integration Tests

```bash
bash /home/coder/coder-packages/autopilot/tests/test_cycle.sh
bash /home/coder/coder-packages/autopilot/tests/test_install_skills.sh
bash /home/coder/coder-packages/autopilot/tests/test_runs.sh
bash /home/coder/coder-packages/autopilot/tests/test_brief.sh
bash /home/coder/coder-packages/autopilot/tests/test_sweep.sh
```

All five must pass — the last three are regression guards, not new coverage.

### Level 4: Manual Validation

```bash
# installer convergence + no new untracked noise in the work repo
cd /home/coder/coder-packages && ./scripts/install-autopilot.sh && ./scripts/install-autopilot.sh --check
git -C /home/coder/root-for-local status --porcelain .claude/skills   # expect empty

# CLI surface
ap limits                       # expect a "review slots (clamped 1-4): 2" line
ap limits --review-slots 3 && ap limits | grep -i review
ap status                       # expect a "review slots:" line alongside plan/build/ship
ap queue --help 2>&1 | grep -- --kind || ap queue 2>&1 | head

# decider dry-run against the REAL queue — never writes
ap decide

# then, with the pipeline PAUSED, a hand-seeded dry run:
ap pause
ap queue ENG-<a-real-low-risk-bug> "smoke test of the bug fork" --kind bug
ap decide                       # expect action:investigate, and a trace line naming the kind branch
ap resume                       # let one real cycle run it

# supervised live end-to-end, one bug, watching each hop:
ap tail latest                  # investigate act
ap sessions                     # expect the ticket at piv-draft-review with "awaiting `ap approve`"
ap approve ENG-<id>             # expect the next cycle to dispatch the fix act
ap sessions                     # expect piv-review-pending after the fix act's DONE
ap runs -n 10                   # expect three ledger rows: investigate, fix, review
gh pr view <n> --json state,reviews   # expect an open, reviewed, UNMERGED PR
```

Success criterion for the live run: **three acts, one open PR, review threads worked, ticket at `ready-to-test`, nothing merged.**

### Level 5: Additional Validation (Optional)

```bash
# port map: confirm no lane overlaps another, or the human's baseline
python3 - <<'PY'
build = {(5173+n, 8000+n) for n in range(1, 5)}
ship  = {(5180+n, 8010+n) for n in range(1, 7)}
review= {(5187+n, 8020+n) for n in range(1, 5)}
human = {(5173, 8000)}
sets = {"build": build, "ship": ship, "review": review, "human": human}
for a in sets:
    for b in sets:
        if a < b:
            fe = {p for p,_ in sets[a]} & {p for p,_ in sets[b]}
            be = {p for _,p in sets[a]} & {p for _,p in sets[b]}
            assert not fe and not be, (a, b, fe, be)
print("no port overlap across plan/build/ship/review/human")
PY

# every state in ap_queue.STATES is handled by ap-runs.py's note renderer
python3 - <<'PY'
import sys; sys.path.insert(0, "/home/coder/coder-packages/autopilot/bin")
import ap_queue, importlib.util
spec = importlib.util.spec_from_file_location("r", "/home/coder/coder-packages/autopilot/bin/ap-runs.py")
m = importlib.util.module_from_spec(spec); sys.modules["r"] = m; spec.loader.exec_module(m)
for s in sorted(ap_queue.STATES):
    note = m._queue_note({"state": s, "history": [{"event": "x"}]})
    assert note and note != s, f"{s} falls through to the bare-state default"
print("every state renders a real note")
PY
```

---

## ACCEPTANCE CRITERIA

- [ ] **AC #1** — `claude/skills/headless-protocol.md` exists, holds the phase-agnostic contract (trigger, `dontAsk` discipline, status vocabulary, parking, `status.json`, generic queue contract, ask→fallback, Linear footprint, background rule, the one `$QUEUE_PY` snippet, the pipelines table), is symlinked into the work repo and installer-managed; `autopilot-protocol.md` is reduced to the feature-path addendum and points at it; `implement-issue`/`ship-work` point at both and no longer duplicate the `$QUEUE_PY` snippet or the background rule.
- [ ] **AC #2** — `ap queue ENG-x --kind bug` records `kind: "bug"`; omitting `--kind` records `feature`; an existing ticket file with no `kind` key reads as `feature` everywhere.
- [ ] **AC #3** — `ap_queue.STATES` contains the five new states; `ap sessions`' status picker offers them; `_queue_note` renders a real note for each.
- [ ] **AC #4** — `AP_REVIEW_SLOTS` (default 2, clamped 1-4) exists; `lock.review.N` is probed lowest-first and reported busy only when full; review ports are `5187+n`/`8020+n` and overlap nothing; `ap status` shows a review slot line; `ap down` refuses while a review slot is held; `ap limits --review-slots` persists; the README documents all of it.
- [ ] **AC #5** — The decider claims `queued`+`kind=bug` → `investigate`, `piv-draft-review`+approval → `fix`, `piv-draft-review`+feedback → `re-investigate`, `piv-review-pending`+free review slot → `review`; every claim is preceded by an `_issue_lock_free` check; every branch emits a trace line.
- [ ] **AC #6** — A feature ticket and a bug ticket competing for the same lane are served in `seq` order; neither fork can starve the other; a busy review lane never blocks a free ship lane.
- [ ] **AC #7** — The wrapper dispatches the three bug prompts with the right flags and ports, writes `piv-implementing → piv-review-pending` itself after a fix `DONE`, requeues an externally-failed bug act to `queued`/`piv-draft-review`/`piv-review-pending` per phase, and parks a bug `NEEDS_HUMAN` with the right `phase_at_question`; `ap-resume.sh` re-acquires a review slot and reconciles bug phases.
- [ ] **AC #8** — A `fix` act **never** chains a review dispatch on its build slot: exactly one claude invocation per cycle for the fix.
- [ ] **AC #9** — `sweep_stale` covers `piv-drafting`/`piv-implementing`/`piv-reviewing`; `ap retry` re-queues each bug phase to the same state the wrapper's external-failure map uses.
- [ ] **AC #10** — `ap status`, `ap sessions`, `ap runs`, and the daily brief all show a bug ticket at every one of its states, with the review-lane act's window parsed correctly.
- [ ] **AC #11** — No orchestrator change alters any legacy state, tier, lane, lock, port, or dispatch prompt: `test_decide.sh`/`test_cycle.sh`'s pre-existing cases pass unmodified.
- [ ] **AC #12** — New/extended tests all pass; the other three harnesses still pass.
- [ ] **AC #13** — `piv-investigate-issue` has a step-7 conditional adversarial gate with an enumerated red-team trigger and a mechanically-checkable challenge trigger; findings and **non-firing triggers** both land in the RCA's `## Adversarial review` section.
- [ ] **AC #14** — The `/challenge` trigger is labelled in the file as a **new convention with no existing precedent in this codebase**; both rubric skills have headless sections that forbid asking, forbid writing, forbid Linear/PR posting, and require reporting an unobtainable replay/ledger-check as a finding.
- [ ] **AC #15** — All five bug-path skills have a `## Headless mode` section that (a) opens with the pointer sentence, (b) states its phase and `phase_at_question`, (c) carries a skill-specific ask-point→fallback table, and (d) **duplicates none** of the protocol's mechanics.
- [ ] **AC #16** — The push uses an explicit `haroun/eng-<id>-fix-<slug>` branch name (never `HEAD`, never a `fix/` prefix); the PR is opened via an allowed call; the permission profile permits every call the bug path makes (git operations via the pre-existing `Bash(git -C *)` allowance, `gh`/`node`/MCP calls via the newly-added grants) and still denies merging (`mcp__github__merge_pull_request` denied at the MCP layer) and Linear comments; raw `--force` push and direct `main`/`dev` pushes stay denied at the Bash-pattern layer. Known residual risk, out of scope to close here: `Bash(gh api *)` is broad enough to technically allow `gh api -X PUT repos/.../pulls/N/merge` — merge prevention for that path rests on skill prose (never instructed) rather than a Bash-level block; see OPEN QUESTIONS #15.
- [ ] **AC #17** — `piv-review-pr`'s headless section resolves every `babysit-pr` ask point: blockers autonomous, non-blockers auto-applied per the stated recommendation with the out-of-diff carve-out, budget boundary → `NEEDS_HUMAN` with the full hand-off payload, every "stop and speak up" item → `NEEDS_HUMAN`, and the merge question → stop at `ready-to-test`.
- [ ] **AC #18** — Nothing in the bug path can merge or approve a PR: verified by reading the skills, by the deny list, and by the live run ending on an open PR.
- [ ] **AC #19** — `install-autopilot.sh` manages every bug-path skill plus the new doc; `--check` reports converged; the work repo's `git status .claude/skills` is empty.
- [ ] Code follows project conventions and patterns (clamp idiom, tier shape, trace lines, pointer-sentence openers, `caseN:` test descriptions).
- [ ] No regressions in existing functionality.
- [ ] Documentation is updated (`autopilot/README.md`, `daily-brief`, both protocol docs).

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task validation passed immediately
- [ ] All validation commands executed successfully
- [ ] Full test suite passes (`test_queue`, `test_decide`, `test_cycle`, `test_install_skills`, `test_runs`, `test_brief`, `test_sweep`)
- [ ] No linting or type checking errors (`shellcheck` clean, `py_compile` clean, JSON parses)
- [ ] Manual testing confirms feature works — one supervised live bug end-to-end, three ledger rows, one open unmerged PR, ticket at `ready-to-test`
- [ ] Acceptance criteria all met
- [ ] Code reviewed for quality and maintainability
- [ ] `ap pause` released and the pipeline resumed after the doc-split phase
- [ ] Rollback path rehearsed: the state-stranding note in Edge Cases is written down where a future operator will find it

---

## OPEN QUESTIONS / ASSUMPTIONS

1. **Assumed — "full replace" means incremental, in three plans, not one.** This plan wires only the bug fork; `--kind feature` keeps running `implement-issue`/`ship-work` unchanged and coexisting; a follow-up plan does the feature fork; a **third** plan removes the legacy path once both are proven. This is a reinterpretation of the brief's "full replace is the end-state target" and it is the single assumption most worth confirming before execution. If instead the intent is a single cut-over, Phases 3-6 change shape substantially (no `kind` field needed at all, no disjoint state sets, no coexistence).

2. **Assumed — the RCA keeps a human approval gate (`piv-draft-review`), reusing `ap approve`/`auto_approve` exactly as `plan-review` does.** The feature brief's step list goes investigate → agentic gate → implement with no human gate named. I have added one, because "review the artifact privately from the phone, then approve" is the pipeline's founding invariant (`docs/plans/2026-08-11-autopilot-pipeline.md:8-20`) and removing it for bugs would be a bigger change than adding the fork. It costs nothing for an operator who wants full autonomy — `ap queue --kind bug --auto` skips it. **If bugs should instead flow investigate → fix with only the agentic gate as protection, drop the `piv-draft-review` state and merge tiers 1/2's bug half into the intake tier.** Confirm before execution.

3. **Assumed — three acts, not six.** `piv-commit` and `piv-create-pr` ride inside the `fix` act because neither has a human-judgment ask point. If per-phase restartability is worth more than the dispatch overhead, they become their own states/tiers; the idempotent-re-entry rule in `piv-implement-issue`'s headless section is what makes the current choice safe, and it is the thing to re-examine if a retried fix ever misbehaves.

4. **Assumed — no browser QA and no four-server baseline comparison on the bug path.** A fix's evidence is its reproduction case plus its regression test. Confirm — `implement-issue`'s Phase B mandates the comparison for features, and the asymmetry is deliberate but arguable.

5. **Assumed — `AP_PLAN_SLOTS` stays at its default of 1.** Investigation reuses the plan lane rather than earning a lane of its own (only one new lane was sanctioned). Consequence: with `AP_PLAN_SLOTS=1`, a bug investigation and a feature plan **serialize**, and since both forks' intake enters only through that lane (`ap-decide.py` tier 5), one long investigate act stalls all new intake of both kinds — the exact bottleneck `AP_PLAN_SLOTS` was introduced to fix for plans (`ap-env.sh:94-112`, the ENG-1407 case). Recommendation: run `ap limits --plan-slots 2` when the bug fork goes live, and document that in the README rather than changing the shipped default. Flagging rather than deciding: changing the default would alter legacy behavior, which this plan otherwise never does.

6. **Assumed — `AP_REVIEW_SLOTS` default 2, clamped 1-4.** Reasoned in the `ap-env.sh` task (CPU-heavy gates like build, long bot-round waits like ship). Genuinely uncertain: if `debate-review`'s 10-20 minute run plus `babysit-pr`'s gate runs turn out to be the workspace's real memory ceiling, 1 is the safer default. Observe the first week and adjust with `ap limits --review-slots`; the clamp range does not need re-planning to tune.

7. **Assumed — a bug ticket's review budget ends at `babysit-pr`'s own built-in 2 repair pushes + 2 re-review cycles**, with no `ap`-level override. If a bug routinely exhausts that and parks, the fix is upstream (a better RCA, a smaller fix), not a bigger budget — but it is worth watching, because `NEEDS_HUMAN` at the budget boundary is the most likely steady-state park point in this fork.

8. **Assumed — the cost profile is acceptable.** A bug now costs three acts (opus investigate + sonnet fix + sonnet review) plus `debate-review`'s two-to-three delegated sessions and `codex-delegate`'s adversarial test pass. `AP_MAX_ISSUES_PER_DAY=3` counts distinct issues, so the cap does not change, but `AP_MAX_DAY_COST_USD=50` may bind sooner. Compounding it: persistent-mode cost figures are **estimates**, not billed amounts (`README.md:184-199`), so the first week's real spend is only knowable from the account. Recommendation: watch `ap status`'s week line for the first few bugs before queueing them in volume.

9. **Open — should `ap retry` for a FAILED `fix` act go back to `piv-draft-review` (re-approve, then re-fix) or straight to `piv-implementing`?** This plan chose `piv-draft-review`, mirroring `implement`'s requeue to `plan-review` exactly. It costs one `ap approve`. The alternative skips the re-approval but loses the "a human saw this before it built again" property. Consistency with the legacy map won; say so if you disagree.

10. **Open — the tier-3 routing of an answered `fix`-phase question to `re-investigate`** mirrors the legacy path's routing of an answered `implement`-phase question to `replan`. It is deliberate consistency, **not** a claim that it is optimal: re-investigating a whole bug because the human answered one implementation question is heavy-handed. In practice it rarely fires (persistent mode injects the reply into the live parked window, and tier 3 excludes parked tickets), which is why consistency was worth more than cleverness here.

11. **Assumed — the `/challenge` trigger as specified is checkable enough to be trusted.** "Any load-bearing link in the Evidence Chain that is not a `file:line` reference" is mechanical, which is the point. It will occasionally fire on a link that is really just a colloquial aside, and occasionally miss a metric smuggled into prose. Both failure modes are cheap (one extra sub-agent, or a recorded skip). This is a **new convention with zero precedent in this codebase** — expect to tune the trigger after the first handful of bugs, and treat the first month's `## Adversarial review` sections as the evidence for whether it earns its cost.

12. **Assumed — `red-team`'s §3 replay will usually report "rows unobtainable."** The `dontAsk` profile allows no DB read tools and no piped queries, and this plan does **not** widen it to allow them (a headless act with database read access is a different risk conversation). The consequence is honest but real: the most empirically powerful part of the red-team rubric will mostly be unavailable to the bug fork. If replays turn out to matter, the follow-up is to add scoped `mcp__mongodb-local__find`/`aggregate` to the allow list — deliberately deferred, not overlooked.

13. **Confirmed by reading, not assumed** — no orchestrator code reads `status.json`'s `plan_path`. `ap-cycle.sh` takes it from the decider's `planPath`; `ap-resume.sh` from the parked registry; `ap-runs.py show` dumps the file verbatim. That is what makes renaming it to `artifact_path` in the new doc safe, and what lets both keys coexist during the migration. Re-verify with a grep before relying on it.

14. **Confirmed by running, not assumed** — the work repo's main checkout is permanently dirty (4 modified tracked files, ~20 untracked paths) and sits on an unrelated branch (`fix/eng-1476-e2e-python-version`). This is the empirical basis for the worktree mandate. If that ever stops being true, the mandate is still right for the concurrency and push-permission reasons.

15. **Flagged by the plan-critic audit — `Bash(gh api *)` is broad enough to technically allow a merge call** (`gh api -X PUT repos/.../pulls/N/merge`), even though `mcp__github__merge_pull_request` is denied at the MCP layer and no skill in this pipeline is ever instructed to call it. This is a **pre-existing** gap in the permission profile, not something this plan introduces — the same grant already existed before this plan and covers the legacy feature path too. Out of scope to close here; worth a follow-up asking whether `gh api *` should be narrowed (e.g. to exclude `-X PUT .../merge`) or whether the current "nothing instructs it" argument is considered sufficient given the profile could technically permit it.

16. **Suggested by Codex's independent second draft, not adopted — an RCA-approval content digest.** Codex proposed recording a hash of the approved RCA's content at `piv-draft-review` approval time, and having the `fix` act refuse to proceed if the RCA file's content has since changed — catching the RCA *document* being edited between approval and fix, which is a different failure mode from `piv-implement-issue`'s existing drift check (which compares the *code* against what the RCA describes, not the RCA against its own approved version). Not implemented in this pass: `ap approve`'s existing semantics already assume an approved artifact doesn't change out from under the approval, exactly the same assumption the legacy `plan-review` gate already makes for plans — so this isn't a new risk this plan introduces, just one neither pipeline currently guards against. Worth adding in a follow-up if RCA edits between approval and fix turn out to be a real occurrence in practice.

---

## NOTES (open canvas)

### The one design property that makes this safe: disjoint state sets

Everything else in this plan is plumbing. The load-bearing idea is that the bug fork's five states never overlap the feature fork's five, which yields three properties worth stating plainly:

1. **`kind` is read in exactly one place.** The `queued` intake tier. Every other claim is a state lookup. So the "does this code path handle both forks?" question — the usual source of coexistence bugs — has a one-word answer everywhere except one `if`.
2. **The legacy path gains no new transitions.** A feature ticket cannot enter a bug state and vice versa, not by policy but by construction. That is what lets AC #11 be checked by running the *unmodified* pre-existing test cases.
3. **The follow-up plan is unblocked, not entangled.** When the feature fork moves to `piv-plan-implementation` → `piv-implement`, it can either reuse the bug fork's states (if the phases align) or add its own; either way it does not have to unpick anything here.

The cost of the property is five extra states in four separate readers, which is exactly where the High complexity rating comes from. That trade is worth naming: **more surface, less coupling.** The alternative — one state set with a `kind` check at every tier — is fewer states and far more places to get a conditional wrong, and it would make "is the legacy path untouched?" unanswerable by inspection.

### Rejected: three separate acts for fix/commit/create-pr

Considered dispatching `fix`, `commit`, and `create-pr` as three sequential `run_claude` calls on the same build slot, the way implement→ship chains. Rejected because: three windows, three park points, three ledger rows, and three reconcile branches for two skills that have **zero human-judgment ask points between them**. The only thing it buys is per-step restartability, and the idempotent-re-entry rule (branch exists + a `Part of ENG-<id>` commit → skip to create-pr; open PR → `DONE`-idempotent) buys that more cheaply. Recorded here because if a retried fix ever double-implements, this is the alternative to reach for.

### Rejected: chaining review after fix on the build slot

The legacy implement→ship chain exists for a historical reason — ship used to be part of implement — and it pays a real price: `ap-resume.sh:431-468` is the most intricate code in the pipeline precisely because a parked `implement` act must tear down its own window and launch a *new* chained-ship window on the same slot. The bug fork has no such history, so it uses the decoupled form: `fix` DONE → `piv-review-pending` → a later cycle claims the review lane. Consequences, all good: a build slot is never held during 20-60 minutes of bot-round waiting; `ap-resume.sh` needs no chained-dispatch branch for the bug path at all; and a review that fails externally requeues to `piv-review-pending` and simply gets picked up again, with no half-finished chain to reason about.

This is the one place where the new fork is *architecturally cleaner* than the old one, and it is an argument for the eventual feature-fork plan to decouple ship the same way.

### The traps that would each have cost a full unattended run

Listed together because they share a shape — interactive prose that reads fine and fails only at runtime, with nobody present to answer:

- **`git push -u origin HEAD`** (`piv-create-pr:66`) does not match the allow-list pattern `Bash(git push -u origin haroun/*)`. Denied, silently, at the last step of the fix act.
- **`fix/issue-<id>-<slug>`** (`piv-implement-issue:62`) is unpushable for the same reason. Hence the `haroun/eng-<id>-fix-<slug>` mandate, which also matches every existing worktree and `piv-plan-implementation`'s `work.branch` convention.
- **`gh pr create`, `gh pr checkout`, `node`, `git checkout`, `git rev-parse`, `git symbolic-ref`** — none on the allow list today.
- **The main checkout is dirty and on an unrelated branch**, so `piv-implement-issue`'s "already on a feature/fix branch? use it" would cheerfully build the fix on `fix/eng-1476-e2e-python-version`, and `piv-create-pr`'s "uncommitted changes → STOP" would fire on unrelated noise.
- **`.claude/reports/` is untracked in the work repo**, so writing the fix report there creates the very dirty-tree condition the next phase hard-stops on. Hence `docs/issues/reports/`, committed.
- **The RCA must be committed**, or the fix act — a different session, hours later, possibly a different worktree — cannot find it, and the investigate act leaves its worktree dirty.
- **`babysit-pr` hard-depends on `jq`** and `debate-review` on `node`; both resolve for an interactive shell here but a cron-launched act's `PATH` inheritance is not guaranteed. Hence the review preflight.
- **A phase name with an underscore** silently breaks `ap runs`/`ap status`/`ap tail` via `ap-runs.py:80-82`'s `(?P<phase>[^_]+)`. Hence `re-investigate`.
- **`sweep_stale`'s state tuple** is the only backstop for a crashed act. Omitting the three new states means a workspace restart mid-bug strands the ticket forever with no diagnostic.
- **`ap down`'s per-slot refusal** is the only thing stopping `tmux kill-session` from taking a live review act down. Omitting the review loop makes `ap down` quietly destructive.

Every one of these is already written into a task's GOTCHA. They are collected here because the pattern — *the interactive form is not the headless form, and the difference is invisible until 3am* — is the single most useful thing to carry into the follow-up feature-fork plan.

### On `autopilot-protocol.md`'s stale `jq` claim

`autopilot-protocol.md:39-40` states "`jq` is not even installed." It is: `/home/coder/.nix-profile/bin/jq`. The claim is stale, and `ap-cycle.sh` itself branches on `command -v jq` throughout. The new doc corrects it without weakening the rule that actually matters — **a piped or compound Bash command is denied unless every segment is allowed** — which is true regardless of what is installed, and which is the real reason the pipeline uses `gh --jq` and `python3` heredocs instead of pipes. Worth noting that the false-but-conservative version of this claim probably prevented some denials by accident; the corrected version has to carry the real rule more emphatically to compensate.

### A latent bug found and deliberately not fixed

`ap-decide.py:47-49`'s `resolve_plan_path` globs `*%s*.md % eng_lower`, so resolving `eng-123` also matches `eng-1234-anything.md` — and with the mtime sort, a newer unrelated ticket's plan can win. It has presumably never fired because the plan lane is mostly serial and ticket ids are far apart. Out of scope here; the new `resolve_rca_path` deliberately does exact-basename-match-first so it does not inherit the hazard, with a comment saying why. Worth its own one-line fix in a follow-up.

### Rollout sequencing

Order matters in exactly two places:

1. **Create and wire `headless-protocol.md` before splitting `autopilot-protocol.md`** (Phase 1 before Phase 2). Acts run 24/7; an act that reads the shrunken addendum mid-turn must find its pointer target already resolvable in the work repo.
2. **Hold `ap pause` across the doc split.** It is the only phase that edits documents a live act may re-read. Everything else is additive to code the running acts do not re-read mid-turn.

Beyond that: land Phases 3-6 (plumbing) and 7 (skills) in either order or in parallel — the plumbing dispatches prompts nothing will send until a bug ticket exists, and the skills are inert until dispatched. Then Phase 8 (permissions/installer), then Phase 9. The first live bug should be queued with `ap pause` held, `ap decide` inspected, and only then resumed.

### Rollback

Every change is additive, so `git revert` restores the legacy pipeline. The one non-obvious hazard: a bug ticket **in flight** at revert time lands in a state that no tier claims *and* no sweep sweeps, because both the tiers and the sweep list are reverted with everything else. It will sit silently at `piv-drafting`/`piv-draft-review`/`piv-implementing`/`piv-review-pending`/`piv-reviewing` forever. Recovery is manual — `ap sessions` → `[s]` → set `failed` or `done` by hand, or `ap sessions` → `[e]` a note explaining it. Check for in-flight bug tickets (`python3 ap_queue.py --ap-home ~/.autopilot list` and grep the new states) **before** reverting, and drain them first if any exist.

---

## PLAN AUDIT — independent model, before this plan is considered done

**Verdict: SOUND WITH FIXES.** Run by `plan-critic` on `fable` (a different reasoning lineage from the `opus` that drafted this plan), reading the actual repository rather than trusting the plan's own claims. It re-derived roughly 150 `file:line` citations against the working tree and found the line-level citation accuracy very high — only a handful of cosmetic offsets were wrong — but surfaced three real problems that have been fixed in the task text above, plus several smaller ones:

1. **Fixed — the permission-profile "denied" claims were partly wrong.** `autopilot/settings/autopilot.json` already allows `Bash(git -C *)`, so most of the `git` verbs the plan claimed were denied (`checkout`, `switch`, `rev-parse`, `symbolic-ref`, `remote show`, `blame`, `show`, `stash`) already pass today via that form. Corrected throughout: the `piv-create-pr`, `piv-implement-issue`, and `piv-commit` headless-task GOTCHAs, the `autopilot.json` task's add-list (the redundant `git` grants removed, only the genuinely-missing `gh`/`node`/MCP ones kept), and AC #16's wording. The branch-naming discipline for pushes stays — it's now framed correctly as a correctness/consistency rule rather than a permission block. `gh` calls (`gh pr create`, etc.) genuinely do need the new grants; that part of the original claim was right.
2. **Fixed — `ap-resume.sh` was missing a `fix`-phase DONE arm that is actually required, not optional.** The plan originally claimed a parked-then-resumed `fix` act "simply reconciles and exits" with no special handling — wrong: without an explicit `fix)` arm writing `piv-review-pending`, such a ticket is permanently stranded at `needs-input` (unclaimed by any tier, unswept by the stale sweep). Added the missing arm, a GOTCHA explaining the general hazard (this reconciliation path is a second, independent implementation from `ap-cycle.sh`'s own, and both must handle every phase or a resumed act silently strands its ticket), and a new regression test case.
3. **Fixed — the installer's exclude-block rewrite would have dropped `autopilot-poll` and broken the plan's own validation.** The live managed exclude block includes a line the plan's proposed `EXCLUDE_BODY` omitted; since the block is replaced wholesale, applying the task as written would have surfaced a dangling symlink as `??`, failing the plan's own "expect empty" check. Fixed with an explicit GOTCHA and a recommendation (delete the dead symlink). Also walked back an earlier suggestion to remove other hand-rolled exclude blocks in the same pass — several currently-symlinked skills aren't in this plan's `SKILL_NAMES`, so that would have broken the same validation a different way; left out of scope.

Smaller fixes applied: `_action_reply_curses` corrected to its real name `_action_feedback_curses`; three off-by-one line citations in the `autopilot-protocol.md` split task corrected; a GOTCHA added noting `test_install_skills.sh` has its own hard-coded skill list that doesn't read the installer's; a known-and-accepted cosmetic gap noted for `ap-runs.py`'s oneshot-mode phase-label heuristic (a fifth reader the plan hadn't enumerated); a GOTCHA added for `test_cycle.sh`'s existing `--feedback` stub override needing to become fork-aware; a GOTCHA added noting the review lane's ports are provisioned but likely unused in practice; and a sizing note flagging the `test_cycle.sh` and `ap-runs.py` tasks as the two most likely to need splitting during actual implementation.

What could not be checked by the audit (see its own report for full detail): live permission-matcher semantics (the `git -C *` finding is about pattern shape, not a confirmed live denial test); whether the existing test suites pass on today's working tree, which carries uncommitted modifications to several of the files this plan touches; `debate-review`/`codex-delegate` script internals beyond confirming the files exist; and the 2026-08-11 autopilot plan's cited invariants weren't independently re-read.

## APPROACH COMPARISON — Codex's independent second draft (Medium/High complexity)

**Grounding caveat, stated prominently because it matters:** Codex's sandbox hit a `bwrap` namespace failure and could not read any local files in this repo — its own final report says so directly ("every filesystem command failed before execution... I cannot honestly claim full compliance with the local-file grounding requirement"). Its proposal is grounded instead in *public upstream* versions of the piv-* skills (`github.com/coleam00/skills`, `github.com/amElnagdy/review-skills`), which may not match this repo's actual local skill content, and it invented at least one nonexistent local filename (`autopilot/bin/ap_env.py` — the real file is `ap-env.sh`), confirming it was inferring rather than reading. Its findings below are weighed as architectural ideas on their own merits, not as verified claims about this codebase.

**Codex's proposal, summarized:** route on the pair `(kind, state)` rather than state alone, with disjoint namespaced bug states (`bug-investigating`, `bug-rca-review`, `bug-fixing`, `bug-reviewing`, plus a separate `bug-review-attention` state) and explicit quarantine of invalid `(kind, state)` combinations; share the plan and build slot pools between forks but give review its own dedicated pool (matching this plan's own choice); keep `piv-commit`/`piv-create-pr` inside the `fix` act with idempotent recovery checkpoints (also matching this plan); run `/challenge` before `/red-team` since a challenge-driven revision to the root cause can change what the fix does; and add several crash-hardening ideas — a durable on-disk ledger for babysit's repair/re-review counters, an RCA-approval content digest, and a check for human pushes to the branch mid-review.

**Grafted into this plan, with why:**
- **`/challenge` before `/red-team` (order swap in step 7).** A genuinely better idea than this plan's original ordering: applied throughout — the step-7 task, the RCA template's `## Adversarial review` subsection order, and the ask-point mapping table now all run challenge first, red-team second, with an explicit note that a challenge-driven fix revision must be evaluated by the subsequent red-team pass, not the pre-revision fix.
- **A stop-condition for a human pushing to the PR branch mid-review.** A real gap this plan's original `babysit-pr` mapping table didn't cover — `babysit-pr`'s repair-push counter and round loop implicitly assume every push during review comes from the act itself. Added as a new row: any push not originating from this act → `NEEDS_HUMAN`, never counted against budget, never rebased over.
- **The RCA-approval-content-digest idea, recorded as a new Open Question (#16) but not implemented.** A genuinely different, complementary defense to this plan's existing drift check (which compares code against the RCA, not the RCA against its own approved version) — worth a follow-up if RCA edits between approval and fix turn out to matter in practice, but `ap approve`'s existing semantics already make the same non-mutation assumption the legacy `plan-review` gate makes for plans, so this isn't a new risk this plan introduces.

**Rejected, with why:**
- **`(kind, state)`-pair routing with invalid-combination quarantine.** This plan's disjoint-state-set design already makes an invalid pairing structurally unreachable — a bug ticket can only ever be in a bug state, checked once at intake — so an explicit quarantine check would be defensive redundancy for a case the type design already rules out.
- **A separate `bug-review-attention` state distinct from the shared `needs-input`.** This plan's `needs-input` + `phase_at_question` field is the exact convention every other phase in both forks already uses; a bug-only alternate needs-attention state would break that consistency for no clear gain.
- **A durable on-disk ledger for babysit's repair/re-review counters**, persisted outside model memory and reconciled against the remote on resume. A reasonable crash-hardening idea in principle, but `babysit-pr` doesn't persist counters this way for the feature path either — this is an interactive-skill-level design question for `babysit-pr` itself, not something this plan's headless-wiring pass should take on unilaterally. Noted as possible future hardening, out of scope here.
- **Keeping `red-team`/`challenge` "unchanged unless inspection shows their return contracts cannot be consumed non-interactively."** This plan already gives both a minimal, deliberate headless section (never ask, report data-access gaps as findings, exact verdict vocabulary) precisely because they're dispatched from inside a headless act in a 24/7 unattended pipeline and need to behave correctly there without a human to fall back on; Codex's more minimal approach is under-specified for that environment.

## AMENDMENTS

- 2026-09-03 — **Bug-specific queue states generalized to a shared, kind-agnostic set**, for
  `docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md` (Phase 2 of this migration), which routes
  `--kind feature` tickets onto `piv-plan-implementation` → `piv-implement` and needed the same five
  pipeline positions. `investigating`→`piv-drafting`, `rca-review`→`piv-draft-review`,
  `fixing`→`piv-implementing`, `review-pending`→`piv-review-pending`, `reviewing`→`piv-reviewing`.
  Phase names stay skill-specific and are unchanged (`investigate`/`re-investigate`/`fix`; the feature
  fork adds `design`/`redesign`/`build`; `review` is now shared). Consequences recorded in this
  document: the "disjoint state sets" invariant becomes "the piv set is shared by both kinds and
  disjoint from the legacy set"; `kind` is now read in **two** decider places, not one (`queued`
  intake and `piv-draft-review`); the ticket field `rca_path` and the decision key `rcaPath` become
  `artifact_path`/`artifactPath` to match the `status.json` generalization this plan already made;
  the `## Pipelines and their phase vocabularies` table gains a third row; `piv-commit`'s and
  `piv-create-pr`'s headless sections gain kind-branched wording (`piv-review-pr`'s was verified
  already kind-agnostic apart from its report-lookup GOTCHA); and `ap-cycle.sh`'s and
  `ap-resume.sh`'s `fix)` arms widen to `fix|build)` so the shared `piv-review-pending` write is
  literally shared. Made **before this plan was executed**, so no live ticket was in any renamed state.
