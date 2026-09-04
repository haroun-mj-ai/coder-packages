# Feature: `ap` feature-path pipeline — route `--kind feature` tickets through the `piv-*` skill family, and generalize the bug fork's states to a shared set

The following plan should be complete, but its important that you validate documentation and codebase patterns and task sanity before you start implementing.

Pay special attention to naming of existing utils types and models. Import from the right files etc.

## Feature Description

This is **Phase 2 of a two-phase migration** of `ap` (the personal 24/7 headless autopilot in `/home/coder/coder-packages`) onto the `piv-*` skill family. Phase 1 — `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md`, drafted, audited (`SOUND WITH FIXES`), **not yet executed** — routes `--kind bug` tickets through `piv-investigate-issue` → a conditional `/challenge`+`/red-team` gate → a human RCA-review gate → `piv-implement-issue`+`piv-commit`+`piv-create-pr` → `piv-review-pr`.

This plan does the other half: `--kind feature` tickets (today's `/implement-issue --phase plan|implement` → `/ship-work` chain, the pipeline's original and only path) move onto **`piv-plan-implementation`** (design) → **`piv-implement`** (build), reusing `piv-commit`, `piv-create-pr` and `piv-review-pr` exactly as the bug fork already does. End state: **every ticket in `ap`, feature or bug, runs through the `piv-*` family.**

It carries three structural pieces beyond the two new skill sections:

1. **A generalization of Phase 1's bug-specific queue states into a shared, kind-agnostic set** — `piv-drafting` / `piv-draft-review` / `piv-implementing` / `piv-review-pending` / `piv-reviewing` — delivered as **direct amendments to Phase 1's document**, not as a third parallel state set. Phase names stay skill-specific (`investigate`/`fix` for bug, `design`/`build` for feature, `review` shared): a state answers *where in the pipeline*, a phase answers *which skill produced this artifact*, and those are different axes.
2. **Two decider tiers that dispatch by `kind`** at the two states both kinds share, and one new artifact resolver for the feature fork's plan file.
3. **Retirement-by-inertness of the legacy path.** `plan`/`replan`/`implement`/`ship` actions, the `/implement-issue` and `/ship-work` dispatch arms, the five legacy states, **and the entire ship lane** become unreachable. Nothing is deleted in this pass — a later, separate cleanup plan does that.

## User Story

As the sole operator of a 24/7 headless autopilot pipeline
I want feature tickets to run through the same `piv-*` chain my bug tickets do — a reviewable plan, a human approval gate, a one-pass build, then an agentic PR review worked to resolution
So that there is exactly one delivery pipeline to reason about, debug and improve, and I still make every merge decision myself.

## Problem Statement

1. **Two pipelines is one too many.** After Phase 1 lands, `ap` has two disjoint delivery chains with duplicated plumbing: two approval-gate states, two "produce an artifact" states, two "implement it" states, two per-phase requeue maps, two sets of reconcile branches in each of two files. Every future orchestrator change costs double, and `ap-resume.sh`'s already-recorded hazard — that its DONE branch is a *second, independent* reconciliation implementation from `ap-cycle.sh`'s, and a phase missing from either strands a ticket permanently (Phase 1's `PLAN AUDIT` finding #2) — doubles with it.
2. **The legacy feature chain is the one part of `ap` nobody re-derived.** `/implement-issue` is a 1300-line skill carrying its own planning process, its own risk classifier, its own QA phase and its own ship handoff, all predating the `piv-*` family. It is not wrong, but it is a parallel investment: `piv-plan-implementation` already has a better-instrumented planning process (a `plan-critic` audit on a different model lineage, a Codex independent second draft, a clarifying gate with a documented headless-safe fallback) and `piv-implement` already has the per-task VALIDATE gate and the Codex adversarial test pass. Keeping both means maintaining both.
3. **The feature path has no agentic review round.** `ship-work` confirms the branch is rebased and locally gate-clean, then stops; bot review findings accumulate unworked until the human sits down. Phase 1 wires `piv-review-pr` + `babysit-pr` in for bugs. Features get nothing until this plan.
4. **Phase 1's state set is bug-shaped by name only.** `investigating`/`rca-review`/`fixing`/`review-pending`/`reviewing` describe the *pipeline position* (produce artifact → human gate → implement → PR open → review), which is identical for a feature. Giving the feature fork a *third* parallel five-state set would triple the readers: `ap_queue.STATES`, `ap-decide.py`'s tiers **and** its stale sweep, three separate state tuples in `ap-runs.py`, `_queue_note`, `daily-brief`'s enumerated sections. Phase 1's own complexity rating came from having four independent readers of five states; fifteen states across four readers is where that design stops paying.
5. **The two skills genuinely new to headless have never been checked for it.** Neither `piv-plan-implementation` nor `piv-implement` has a `## Headless mode` section, so under `claude -p`/`dontAsk` they hit ask points with no documented default, no `status.json` write and no queue write — the wrapper reconciles every one as a crash. Two of those ask points are already known to be traps: `piv-implement`'s bare "STOP: commit or stash first" on a dirty base branch has no stated default at all, and both skills default their output artifacts into `.claude/` — **verified untracked (`??`) in the work repo's main checkout**, the exact dirty-tree trap Phase 1 hit for the bug fork's fix report.

## Solution Statement

**Immediate full cutover, no pilot flag, no `--engine legacy|piv` coexistence period.** Every `kind: feature` ticket — and every ticket with no `kind` key, since `feature` is the default — routes to the piv fork from the moment this plan ships.

The reasoning, stated here because it is the load-bearing scope decision: **by the time this lands, the genuinely risky half is already proven live.** `piv-commit`, `piv-create-pr`, `piv-review-pr` and `babysit-pr`'s headless behavior — the permission-sensitive, network-touching, PR-mutating half, and the half where an unattended mistake is visible to other people — will have been exercised by the bug fork under Phase 1. What is actually new-to-headless here is `piv-plan-implementation` and `piv-implement`: two read-and-write-local-files skills whose worst failure mode is a bad plan sitting at an approval gate, or a failed build act that requeues. That is a materially smaller unproven surface than the bug fork itself took on in one step, and it does not justify the cost of a dual-engine flag — which would mean a third dispatch path, a third set of test cases, and a flag whose removal is its own follow-up plan.

The design:

- **One generalized state set, shared by both kinds, disjoint from the legacy five.** `piv-drafting` (the act producing the reviewable artifact is running) / `piv-draft-review` (that artifact is committed and awaiting `ap approve`) / `piv-implementing` / `piv-review-pending` / `piv-reviewing`. Delivered by amending Phase 1's document, so exactly one document describes the piv state machine.
- **Phase names stay skill-specific.** bug: `investigate`, `re-investigate`, `fix`; feature: `design`, `redesign`, `build`; shared: `review`. A ledger row, a window name and a `phase_at_question` all keep telling you which skill ran.
- **`kind` is read in exactly two places** — the `queued` intake tier and the `piv-draft-review` tier, the only two states where both kinds sit and the next action differs. Every other tier is determined by state alone (tier 4, the sweep) or by *phase* alone (tier 3 — `investigate`/`fix` are bug-only phase names and `design`/`build` are feature-only, so `phase_at_question` already encodes the kind without a `kind` read).
- **Three acts per feature, mirroring the bug fork exactly.** `design` on the plan lane (no ports, produces a committed plan); `build` on the build lane with its port pair; `review` on the review lane. `piv-commit` and `piv-create-pr` ride inside the `build` act, same reasoning as Phase 1: neither has a human-judgment ask point.
- **No chain.** `build` writes `piv-review-pending` and a later cycle claims the review lane — inheriting the decoupling Phase 1 identified as the one place its fork was architecturally cleaner than implement→ship. This is what finally kills the implement→ship chain, `ap-resume.sh`'s most intricate code, by making it unreachable.
- **A conditional `/red-team` gate on the plan, no `/challenge`.** `piv-plan-implementation` gets the same step-7 guard-touching red-team conditional `implement-issue/SKILL.md:354-399` already has and Phase 1 mirrored onto `piv-investigate-issue`. It does **not** get `/challenge`: `/challenge` attacks the provenance of a *measurement* an existing conclusion rests on, and a forward-looking implementation plan has no root-cause evidence chain to attack — its claims are about what the code currently does (`file:line`, which `plan-critic` already re-derives in Phase 5b) and about what the change will do (which is exactly `/red-team`'s question). Stated explicitly rather than silently omitted.
- **The legacy path is left inert, not deleted.** Every legacy state, tier, action, dispatch arm, lock, port range and prompt stays byte-identical and simply stops being reachable from the decider. That is not tidiness: a hand-set legacy state via `ap sessions [s]` remains a working manual escape hatch while the piv feature fork is unproven in production, which is the one safety property an immediate full cutover otherwise gives up. "No legacy path was modified" is checked by reading the dispatch code and by the pre-existing test cases exercising the still-reachable `plan-review`/`ship-pending` escape hatches passing unmodified — **not** by the `queued`-seeded cases, whose expected intake behavior genuinely changes and which must be rewritten (see the `test_decide.sh`/`test_cycle.sh` tasks).

## Out of Scope / Non-Goals

- **Not included: deleting any legacy code.** `/implement-issue`'s `plan`/`replan`/`implement` dispatch arms, `/ship-work`'s `ship` arm, the implement→ship chain in both `ap-cycle.sh` and `ap-resume.sh`, the five legacy states, tiers 1/2's `plan-review` half, tier 4's `ship-pending` half, `REQUEUE_STATE`'s legacy rows, and **the entire ship lane** (`AP_SHIP_SLOTS`, `lock.ship.N`, ports `5181-5186`/`8011-8016`, `ap down`'s ship refusal, `ap status`'s ship slot line, `ap limits --ship-slots`, `ap-resume.sh`'s `ship)` lane arm) all become dead in this pass and all stay in the tree. A later, separate cleanup plan removes them. Every dead arm gets one inert-marker comment naming this plan and that follow-up; nothing else changes.
- **Not included: reclaiming the ship lane's port range.** `5181-5186`/`8011-8016` go idle and stay reserved. The review lane keeps `5187+n`/`8020+n` as Phase 1 assigned it. Renumbering to close the gap is cleanup-plan work.
- **Not changing: `AP_PLAN_SLOTS`'s shipped default of 1.** Raising it to 2 becomes a documented rollout step (see Rollout sequencing), not a default change — Phase 1 declined to change it for the same reason and this plan does not reopen it.
- **Not included: browser QA, the four-server baseline comparison, the durable QA artifact under `docs/plans/qa/`, `roborev`, and the spec-vs-test audit.** These are `implement-issue` Phase B capabilities with **no equivalent in `piv-implement`**, and porting them would recreate most of the surface this cutover exists to retire. This is a real capability regression and it is named honestly in OPEN QUESTIONS #3 — the argument for accepting it is that browser QA relocates to the human's own `/test-issue` session at `ready-to-test`, which already assembles the PRs, stands up the changed-vs-baseline comparison and runs the e2e spec, and which is where the merge decision is made anyway. Two of Phase B's gates are *not* accepted as losses and are ported explicitly (the scope gate and the secrets gate — see the `piv-implement` task).
- **Not included: a headless section for `piv-fix-review-findings`, `piv-review-changes`, `piv-validate`, `piv-slice-epic`.** `piv-validate` is invoked *inside* `piv-review-pr`'s Phase 3 and `piv-implement`'s step 4 as a sub-step, never dispatched as its own act.
- **Not included: fixing `resolve_plan_path`'s substring hazard** (`ap-decide.py:47-49`). Phase 1 declined it; this plan declines it again and deliberately does not inherit the shape — `resolve_piv_plan_path` anchors instead.
- **Not included: any change to the `never merges` invariant.** `piv-review-pr`/`babysit-pr` refuse structurally; `mcp__github__merge_pull_request` stays denied.

## Feature Metadata

**Feature Type**: Enhancement
**Estimated Complexity**: **Medium-High**
**Primary Systems Affected**: `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` (amended in place), `claude/skills/` (`piv-plan-implementation`, `piv-implement`, plus amendments to Phase 1's `piv-commit`/`piv-create-pr`/`piv-review-pr`/`headless-protocol.md` task text), `autopilot/bin/` orchestrator (`ap_queue.py` states, `ap-decide.py` tiers + resolver, `ap-cycle.sh` dispatch/reconcile, `ap-resume.sh` reconcile, `ap-runs.py` state readers), `autopilot/settings/autopilot.json` (one read-only tool), `autopilot/tests/`, `autopilot/README.md`, `daily-brief`
**Dependencies**: no new libraries. Runtime tools already required by Phase 1 and unchanged here: `gh`, `jq`, `node`, `kata` (best-effort). One new **tool permission**: `WebSearch` (read-only) for `piv-plan-implementation`'s Phase 3.

**Why Medium-High, not High, and not Medium.** Less net-new surface than Phase 1 by every structural measure: **zero** new lanes, **zero** new locks, **zero** new port ranges, **two** new env vars (`AP_DESIGN_MODEL`, `AP_BUILD_MODEL` — both optional model-pin overrides with sane defaults, not new lanes or concurrency knobs), **zero** net-new queue states (five are *renamed*, not added), and no permission expansion beyond one read-only tool. The downstream half — the review lane, `piv-review-pr`, `babysit-pr`, `piv-create-pr`, the shared headless protocol doc — is inherited whole and needs verification, not design. That rules out High.

Two things keep it above plain Medium. **(a) It is the first plan in this repo whose primary deliverable is edits to another, unexecuted plan document.** A missed occurrence in Phase 1's 1071 lines does not fail a test — it produces a silently inconsistent instruction set that only surfaces when someone implements the stale half and wires a `fixing` state into a machine that expects `piv-implementing`. **(b) The rename is 5 names across ~137 occurrences with genuine English-prose false positives**: `fixing` appears twice as an ordinary verb ("Not included: fixing `resolve_plan_path`'s substring hazard"), and the `APPROACH COMPARISON` section records Codex's own rejected `bug-investigating`/`bug-rca-review`/`bug-fixing`/`bug-reviewing` vocabulary verbatim as historical fact, which must **not** be renamed. A blind `sed` corrupts the document. The mitigation is that every amendment below is anchored on matched text and a section header rather than a line number, and every prose exemption is enumerated.

**Sizing note for whoever implements this**: the Phase-1 amendment pass is one task in this document but ~30 distinct edit sites in practice — it is the unit most likely to want splitting into "state rename", "field/key rename", and "shared-section content" sub-passes.

## Related Work

**Implements**: no ticket (free-form, personal-tool repo) · **Epic**: none

**Back-references**:

- `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — Phase 1 of this same migration, and **this plan's primary source of truth for conventions**. Inherit verbatim and do not reopen: the `kind` field and its `feature` default; the `headless-protocol.md` split; the review lane and its ports; the pointer-sentence opener; the ask-point mapping-table shape; the `haroun/eng-<id>-*` branch mandate; the worktree mandate and its three reasons; the "wrapper owns the state swap, the skill never writes its own terminal state" rule; the conditional-adversarial-dispatch template; the `_issue_lock_free`-before-every-claim rule. **This plan amends that document directly** (see the amendment tasks) rather than layering a second description of the same machinery on top.
- `docs/plans/2026-08-11-autopilot-pipeline.md` — the plan that built `ap`. Its settled calls stand: never merge autonomously; plan review is private (local queue, never Linear); `flock`-based mutual exclusion; per-rolling-day budgets; skills read from `coder-packages/claude/skills/` as the single source of truth.

**Forward-references**:

- (expected) the legacy-removal cleanup plan — deletes `implement-issue`/`ship-work` dispatch, the five legacy states, tiers 1/2's `plan-review` half, tier 4's `ship-pending` half, the implement→ship chain in both reconcilers, and the whole ship lane, once both piv forks are proven in production.

---

## CONTEXT REFERENCES

### Relevant Codebase Files IMPORTANT: YOU MUST READ THESE FILES BEFORE IMPLEMENTING!

**The document being amended**

- `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` (whole file, 1071 lines) - Why: **read it in full before touching anything here.** Every task in this plan either amends it or depends on a convention it establishes. Its `## STEP-BY-STEP TASKS` section is the target of ~30 edits; its `## AMENDMENTS` section (currently a placeholder) receives this plan's dated entry.

**Skills gaining headless sections**

- `claude/skills/piv-plan-implementation/SKILL.md` (lines 11-25, 27-45, 47-64, 96-181, 183-206, 217-242, 243-525, 527-548, 550-592, 594-601) - Why: input resolution (a Linear id is the headless-only form); the **multi-repo worktree section, which already exists and is already correct** — headless only removes its opt-out; the kata mirror, likewise; Phase 2's clarifying **GATE** and its `If they decline` fallback at `:176-178`, which is the whole answer to the interactive-gate question; Phase 3's external research (needs `WebSearch`); Phase 4's opus dispatch; the Phase 5 template that gains an `## Adversarial review` section; Phase 5b (`plan-critic`/`fable`) and its `DO NOT IMPLEMENT` verdict, the one genuinely new park point; Phase 5c (Codex second draft, `node relay.mjs --read-only`); and the `## Output Format` block at `:594-601` (`.claude/plans/{kebab-case-name}.md`) that headless overrides.
- `claude/skills/piv-implement/SKILL.md` (lines 13-20, 22-48, 50-85, 87-115, 116-124, 125-166, 168-180, 191-225) - Why: the kata resume block; the **branch-selection block headless must override**, containing the bare `STOP: commit or stash first` at `:46` and the `stop and ask rather than recreating it` dirty-worktree stop at `:37-39` plus the `HEAD..origin/dev` staleness check; the implementer/`codex-feature` dispatch policy and the **escalation ladder** at `:77-85` (fix-it-yourself, else an independent read-only Codex diagnosis) which is this skill's real park point; the per-task `VALIDATE` gate at `:112-114`; the Codex adversarial test pass at `:125-166`; step 4's unbounded `fix and re-run` loop at `:176-179`; and the output report at `:191-225` with its `.claude/reports/<plan-slug>-report.md` path and `COMPLETE | PARTIAL` status field.

**Orchestrator**

- `autopilot/bin/ap_queue.py` (lines 26-29, 93-108, 116-136, 178-191) - Why: `STATES`, which receives the generalized names instead of Phase 1's bug names; `list_queue`'s multi-state form (added by Phase 1, reused unchanged); `new_ticket`'s schema, where Phase 1's `rca_path` becomes `artifact_path`.
- `autopilot/bin/ap-decide.py` (lines 38-55, 86-100, 120-131, 136-301) - Why: `resolve_plan_path` (`:38-55`) is the pattern `resolve_piv_plan_path` mirrors **and the substring hazard it must not inherit** (`*%s*.md` matches `eng-1234` when resolving `eng-123`); `sweep_stale`'s state tuple; `_issue_lock_free`'s docstring, whose mid-shutdown race applies identically to `piv-draft-review`; every tier Phase 1 restructured and this plan branches.
- `autopilot/bin/ap-cycle.sh` (lines 420-434, 447-511, 560-603, 803-850, 915-930, 1003-1029) - Why: the decision-key parse block (`.artifactPath` replaces Phase 1's `.rcaPath`); the action→lane/slot/port case statement, whose `plan|replan)` arm gains `design|redesign` and whose `implement)` arm's ports are what `build` reuses; `act_model` (`:572-579`); `window_name_for` (`:595-603`); the dispatch case (`:803-850`) whose `implement)` arm at `:813-833` **is the implement→ship chain that becomes unreachable**; the external-failure requeue map (`:920-924`); and the DONE branch (`:1003-1029`).
- `autopilot/bin/ap-resume.sh` (lines 298-344, 415-470, 472-494) - Why: the lane re-acquisition `case "$lane"` (`:302-327`); the DONE branch (`:421-470`) — **a second, independent reconciliation implementation from `ap-cycle.sh`'s**, whose `implement)` arm at `:431-468` becomes unreachable and whose new `fix)` arm (added by Phase 1's audit fix) must widen to `fix|build)`.
- `autopilot/bin/ap-runs.py` (lines 80-82, 427, 518-555, 833, 1063, 1378-1383) - Why: `_ACT_WINDOW_RE` (phase group is `[^_]+` — **no underscore in a phase name**); `QUEUE_DASHBOARD_STATES` (`:427`); `_queue_note` (`:518-555`) including its `("building","planning","shipping")` no-live-session fallback at `:553`; `TERMINAL_STATES` (`:833`, unchanged); `PENDING_STATES` (`:1063`); `REQUEUE_STATE` (`:1378-1383`), which must match `ap-cycle.sh`'s requeue map exactly.
- `autopilot/bin/ap-env.sh` (lines 94-121) - Why: `AP_PLAN_SLOTS`, default 1, clamped 1-4, and the ENG-1407 bottleneck comment that becomes the rollout argument for raising it to 2.

**Shared skills verified for kind-agnosticism**

- `claude/skills/piv-commit/SKILL.md` (whole file, 33 lines) - Why: **verified kind-agnostic in its own text** (no ENG-id, no bug/fix/RCA vocabulary anywhere) — but Phase 1's *headless section for it* is not, in two places. See the amendment task.
- `claude/skills/piv-create-pr/SKILL.md` (lines 34-48, 55-59, 63-90) - Why: the Phase 1 precondition table Phase 1 already maps; **`:57-59`, the `Implementation report (if piv-implement wrote one — .claude/reports/<…>-report.md)` lookup that needs the kind branch**; the body template.
- `claude/skills/piv-review-pr/SKILL.md` (lines 21-32, 34-42, 44-46) - Why: PR resolution and state guard (kind-agnostic); **`:34-38`, the second `.claude/reports/*{branch}*` implementation-report lookup**, which Phase 1 already points at the bug path and which needs the same kind branch.
- `claude/skills/implement-issue/SKILL.md` (lines 354-399, 1233-1310) - Why: step 7b, the red-team conditional this plan mirrors onto `piv-plan-implementation`; and `--phase implement`'s headless section, the source of the **scope gate** and **secrets gate** mappings (`:1268-1275`) this plan ports to `piv-implement`, plus the `--ports`/CORS rule (`:1286-1291`) and the "do not change the ticket's state, the wrapper does" end-state note (`:1300-1303`).

**Tests, docs, permissions**

- `autopilot/tests/test_decide.sh` (lines 21-33, 43-61, 92-110) - Why: harness header, `seed_ticket` (JSON-decodes extra fields, so `kind=feature` works as-is), `setup_case`, `run_decide`.
- `autopilot/tests/test_cycle.sh` (lines 24-91, 98-183, 289-333) - Why: `seed_plan_file` at `:85-91` (creates `docs/plans/<eng-lower>-thing.md` — **already the shape `resolve_piv_plan_path` resolves**, so the piv helper is a two-line variant); the `claude` stub's phase detection at `:114-121` and its **blanket `--feedback → replan` override at `:121`** which Phase 1 already flags as needing to become fork-aware and which now needs a third branch; `AP_TEST_VARS` (`:291-299`); `setup_case`'s `unset` line (`:307`).
- `autopilot/settings/autopilot.json` (lines 4-60) - Why: **verified — the feature fork needs nothing Phase 1 does not already add, with one exception.** `mcp__linear-server__get_issue`/`list_comments`/`save_issue` are already allowed; `Bash(node *)` is added by Phase 1 for `debate-review`/`codex-delegate` and covers Phase 5c and step 3b; `WebFetch` is allowed. **`WebSearch` is not** — the one new grant.
- `autopilot/README.md` (lines 32-59, 121-150, 201-237, 239-256, 339-352) - Why: env-var docs, the decider section, the concurrency table and per-lane rationale, `ap down`'s documented refusal, and the lock list.
- `claude/skills/daily-brief/SKILL.md` (lines 21-31, 57-102, 121+) - Why: the input contract and the per-state digest sections, one per state.

### New Files to Create

- `autopilot/tests/test_piv_states.sh` — *(optional, see the task)* a single guard test asserting the generalized state set, the shared-state kind branches, and that no legacy state name appears as a substring of a piv state name.

*(No new orchestrator files. Every change is inside an existing file, deliberately: `ap-resume.sh`'s header records this repo's "duplicate small helpers rather than share them" convention.)*

### Relevant Documentation YOU SHOULD READ THESE BEFORE IMPLEMENTING!

No external documentation required — internal-only change to a personal tool, no new library or API. Phase 3 of the planning process was skipped on that basis, same as Phase 1.

Three internal cross-references are load-bearing and cited above rather than externally:

- `implement-issue/SKILL.md:354-399` — the live conditional red-team dispatch and the ENG-1406 case that justifies it. The pattern, not a suggestion of one.
- `implement-issue/SKILL.md:1268-1275` — the live headless scope/secrets gate mappings, ported wholesale rather than re-invented.
- `arXiv:2607.21656` as cited in `piv-plan-implementation/SKILL.md:541-548` and `:556-559` — why Codex is the *generator* (Phase 5c second draft, step 3b adversarial test) and never the *reviewer* of Claude-authored work. Preserve that direction in every dispatch.

### Patterns to Follow

**Queue state writes (skill-side).** One `set` call per transition, state + fields + a human-readable event, per Phase 1's `headless-protocol.md` contract:

```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state <new-state> \
  --field key=value --event "description"
```

`$QUEUE_PY` resolved once per session from the core doc's single copy of the snippet.

**Headless section opener.** The pointer sentence, verbatim in shape from Phase 1:

> Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own ask points map to.

**Ask-point mapping table.** Three columns: ask point (with `SKILL.md:line`) | headless resolution (`documented default` / `NEEDS_HUMAN` / `FAILED` / `DONE-idempotent`) | what gets recorded. This table is the *whole* skill-specific payload; mechanics never repeat.

**Decider tier (`ap-decide.py:245-269`).** Lane-busy guard → seq-ordered `list_queue` → per-entry `_issue_lock_free` → resolve the artifact (or `needs-input` + `continue`, never `break`) → `transition(...)` claim → decision dict → `break`. A `trace(...)` on **every** branch including skips.

**Conditional adversarial dispatch (`implement-issue/SKILL.md:354-399`).** Bold **Conditional. Skip it and say so unless the trigger below fires**; an enumerated trigger list; a *why this exists and the cheaper check does not cover it* paragraph; a fresh `Agent` given the delta and the current code/tests but **not** the argument for the change; a numbered require-back list; and "record the trigger decision when it did not fire, so the skip is auditable."

**Branch naming.** `haroun/eng-<id>-<slug>` for a feature (already recorded as `work.branch` at `piv-plan-implementation/SKILL.md:57`), `haroun/eng-<id>-fix-<slug>` for a bug (Phase 1's mandate). Both match the profile's only push grant, `Bash(git push -u origin haroun/*)`. **Never** `feature/<plan-slug>` as `piv-implement/SKILL.md:44` says interactively.

**Test case (`test_cycle.sh:387-397`).** Banner comment stating the case's intent, `setup_case`, `seed_ticket`, env knobs, `run_case`, then one `assert` per distinct claim with a `caseN: <claim>` description.

---

## IMPLEMENTATION PLAN

Phases run **top to bottom by default**. Where that is NOT the true dependency, it is annotated.

### Phase 0: The Phase-1 amendment pass — do this before Phase 1 is executed

**Hard sequencing constraint, and the single most important line in this plan:** Phase 1's document has **not** been implemented. `ap_queue.STATES` does not contain `investigating`/`rca-review`/`fixing`/`review-pending`/`reviewing`, and the live queue holds **24 tickets, every one of them in a terminal state** (`done`/`ready-to-test`/`failed`, verified 2026-09-03). So the state rename is a **documentation edit against unexecuted instructions**, with zero live data to migrate.

**Do this phase before Phase 1 is executed.** If Phase 1 has already been executed when this plan starts, this phase becomes a live-data migration and the conditional task at the end of this plan applies instead.

### Phase 1: Ticket schema and orchestrator plumbing for the feature fork

**Depends on:** Phase 0 (the amended Phase-1 doc is what gets implemented), and on Phase 1's own Phases 3-6 being executed.

`ap_queue.py`'s generalized `STATES` and `artifact_path`; `resolve_piv_plan_path`; the two kind branches in `ap-decide.py`; `design`/`redesign`/`build` through `act_model`, both requeue maps, both reconcilers, and `ap-runs.py`'s readers.

### Phase 2: The two new skill headless sections and the red-team gate

**Depends on:** Phase 1's Phases 1-2 (the `headless-protocol.md` pointer target must exist and resolve in the work repo). **Independent of:** this plan's Phase 1 — these are prose files with no code dependency on the plumbing, authorable in parallel. The end-to-end run needs both.

`piv-plan-implementation` (step 7 red-team gate + the template's `## Adversarial review` section + the headless section), `piv-implement` (headless section).

### Phase 3: Permissions, docs, dead-code markers

**Depends on:** Phase 2 (the exact tool calls determine the allow list).

`WebSearch` in `autopilot.json`; `autopilot/README.md`; `daily-brief`; the inert-marker comments on every dead legacy arm.

### Phase 4: Testing & validation

**Depends on:** all previous phases.

`test_decide.sh` / `test_cycle.sh` extensions scoped to feature-kind dispatch through the shared states, the full regression suite, then one supervised live feature end-to-end.

---

## STEP-BY-STEP TASKS

IMPORTANT: Execute every task in order, top to bottom. Each task is atomic and independently testable.

### Task Format Guidelines

- **CREATE**: New files or components
- **UPDATE**: Modify existing files
- **ADD**: Insert new functionality into existing code
- **REMOVE**: Delete deprecated code
- **REFACTOR**: Restructure without changing behavior
- **MIRROR**: Copy pattern from elsewhere in codebase

---

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — generalize the five queue state names

- **IMPLEMENT**: Rename, throughout Phase 1's document, wherever the token is used **as a queue state**:

  | Phase 1 name | generalized name | rationale |
  |---|---|---|
  | `investigating` | `piv-drafting` | the act producing the reviewable artifact is running — an RCA for a bug, an implementation plan for a feature |
  | `rca-review` | `piv-draft-review` | that artifact is committed and awaiting `ap approve` / `ap reply` |
  | `fixing` | `piv-implementing` | the approved artifact is being implemented |
  | `review-pending` | `piv-review-pending` | PR open, agentic review owed, waiting on a review lane |
  | `reviewing` | `piv-reviewing` | the review act is running |

  **Naming rationale, to be recorded in the amended Solution Statement** (three properties, in priority order):
  1. **Kind-agnostic without being abstract.** A plan and an RCA are both *drafts pending a human's approval* — that is literally true of each, and it is what the state means. `piv-designing`/`piv-design-review` was considered and rejected: "design review" is wrong for a bug (you review a diagnosis, not a design), and the whole point of the generalization is a word that fits both. `piv-drafting`/`piv-draft-review` also morphologically mirrors the legacy pair `planning`/`plan-review`, so the mapping is obvious to anyone who knows the old machine.
  2. **No new state name contains a legacy state name as a substring.** This is a hard rule for the whole set, not a coincidence: `grep 'building'` must not match a piv state, because Phase 1's own VALIDATE lines and this repo's audit habit are grep-based. It is specifically why the third state is **`piv-implementing`, not `piv-building`** — `piv-building` contains `building`. Check the whole set against `{queued, planning, plan-review, needs-input, building, shipping, ship-pending, ready-to-test, failed, done}` before accepting any alternative name.
  3. **The `piv-` prefix makes the fork visible at a glance** in `ap sessions`, `ap runs`, `daily-brief` and every `history` event, and guarantees disjointness from the legacy five by construction rather than by inspection.

- **IMPLEMENT — the exact edit sites**, addressed by **matched text and section header, never by line number** (this document's own line numbers shift as these edits land, and several of these edits are in the same paragraph):

  1. **Feature Description**, the paragraph beginning `The fork is selected by a new `kind` field` — the parenthetical listing the five states.
  2. **Solution Statement**, the bullet beginning `- **Disjoint states.**` — rewrite the whole bullet (see the next task, which changes its content, not just its names).
  3. **CONTEXT REFERENCES → Orchestrator core**, the `ap-decide.py` bullet's phrase `the new `rca-review` tier inherits verbatim`.
  4. **`CREATE claude/skills/headless-protocol.md`** task → the `## Pipelines and their phase vocabularies` table (see the dedicated task below, which restructures it).
  5. **`UPDATE autopilot/bin/ap_queue.py`** task, sub-item 1 — the five quoted strings added to `STATES`, and the comment splitting the set into shared / feature-path / bug-path, which becomes **shared / legacy-feature-path / piv (both kinds)**.
  6. **`UPDATE autopilot/bin/ap-runs.py`** task, sub-items 3, 4, 5, 6 — `QUEUE_DASHBOARD_STATES`, `PENDING_STATES`, `_queue_note`'s three branches and its no-live-session fallback, and `REQUEUE_STATE`'s four new rows.
  7. **`ADD claude/skills/piv-investigate-issue/SKILL.md — ## Headless mode`** task, sub-items 6 (the ask-table row for a Confidence-LOW RCA) and 8 (the end-state `--state rca-review` bash block, and the VALIDATE line's `grep` alternation).
  8. **`ADD claude/skills/piv-implement-issue/SKILL.md — ## Headless mode`** task, sub-items 4 (re-entry from `rca-review`) and 8 (the "it stays `fixing`; the wrapper swaps it to `review-pending`" note).
  9. **`UPDATE autopilot/bin/ap-decide.py — tiers 1/2`** task — both IMPLEMENT bullets and both GOTCHAs.
  10. **`UPDATE autopilot/bin/ap-decide.py — tier 3/4/5, stale sweep`** task — sub-items 1, 2, 3, 4.
  11. **`UPDATE autopilot/bin/ap-cycle.sh — dispatch`** task, sub-item 5 (the `queue_set --state review-pending` line).
  12. **`UPDATE autopilot/bin/ap-cycle.sh — reconcile`** task, sub-item 1 (the requeue map).
  13. **`UPDATE autopilot/bin/ap-resume.sh`** task, sub-item 2 (the `fix)` arm's `queue_set`).
  14. **`ADD claude/skills/piv-review-pr/SKILL.md`** task, sub-item 8's "without this write the ticket never leaves `reviewing`".
  15. **`UPDATE claude/skills/daily-brief/SKILL.md`** task — all five state names and the VALIDATE grep. **GOTCHA specific to this site**: Phase 1's daily-brief sections use bold, capitalized titles (`**Investigating**`, `**Fixing**`, `**Reviewing**`) — the Level-2 VALIDATE grep is lowercase and will not flag these if left unrenamed. Check the capitalized section-title forms by hand; do not rely on the grep for this file.
  16. **`UPDATE autopilot/tests/test_decide.sh`** task — cases 1, 3, 4, 5, 6, 7, 8, 9, 10, 13.
  17. **`UPDATE autopilot/tests/test_cycle.sh`** task — the new-case bullets naming `investigating`, `review-pending`, and the parked-and-resumed `fix` case.
  18. **VALIDATION COMMANDS → Level 4** — the `ap sessions` expectation lines.
  19. **ACCEPTANCE CRITERIA** — AC #3, AC #5, AC #7, AC #9.
  20. **TESTING STRATEGY → Edge Cases** — the `review-pending`-with-empty-`pr_urls` bullet.
  21. **OPEN QUESTIONS** #2, #9.
  22. **NOTES → Rollback** — the list of five states a mid-flight ticket can strand in.
  23. **PLAN AUDIT** finding #2 — the `review-pending` reference in the `ap-resume.sh` fix.

- **GOTCHA — the edit-site list above is a starting map, not a complete enumeration; the audit found it undercounts.** The Level-2 VALIDATE grep below actually matches roughly 68 lines in Phase 1's document today, not the 23 sites listed plus a handful of exemptions — missed sites include the Solution Statement's "No chain" bullet (which itself writes `review-pending`), two `IMPLEMENTATION PLAN` phase-summary sentences, the `ap-runs.py` curses-guard sub-item accepting `rca-review`, the DONE-branch notify text `RCA auto-approved, fixing:` (a real state reference needing renaming, not an exemption), an Open Question, and a NOTES bullet titled "Rejected: chaining review after fix." Do not treat the 23-item list as sufficient. Instead: **apply the rename globally per the state-name table above, then run the Level-2 VALIDATE grep below and manually classify every remaining hit** as either (a) a real state reference that still needs renaming — fix it — or (b) one of the two ordinary-English "fixing" verb usages named below. Treat any hit that is neither as a signal the rename pass missed something, not as an expected exemption. This turns a brittle enumerated list into a self-correcting process, which is the honest fix given the enumeration above is known-incomplete.
- **GOTCHA — exactly two prose exemptions, not three.** Only these are ordinary English usage that must NOT be renamed:
  - **Out of Scope**, the bullet `- **Not included: fixing `resolve_plan_path`'s substring hazard**` — `fixing` here is an ordinary English verb.
  - The `resolve_rca_path` task's GOTCHA phrase `fixing the plan-path version is out of scope here` — likewise.
  - **Not a third exemption, despite appearances**: **APPROACH COMPARISON**'s record of Codex's rejected `bug-investigating`/`bug-rca-review`/`bug-fixing`/`bug-reviewing`/`bug-review-attention` vocabulary never actually matches the grep pattern below in the first place — each token is preceded by a hyphen (`bug-fixing`, not word-boundary `fixing`), and the pattern's `[^-a-z]` boundary class excludes a preceding hyphen, so these hits never appear and need no exemption. Leave this historical record untouched regardless (renaming Codex's own rejected proposal would rewrite what was actually rejected), but don't expect it to show up in the grep output — if it does, the boundary logic assumption was wrong and needs re-checking.
- **GOTCHA**: check every `grep` inside a **VALIDATE** line after renaming — several use `\|` alternations over these tokens and will silently pass against nothing if a name changes but the grep does not.
- **VALIDATE**: `cd /home/coder/coder-packages && grep -nE '(^|[^-a-z])(investigating|rca-review|fixing|review-pending|reviewing)([^-a-z]|$)' docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` → expect exactly the two prose exemptions above and nothing else; classify anything else per the self-correcting process above.
- **SATISFIES**: AC #1

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — the invariants the rename changes

- **IMPLEMENT**: Three claims in Phase 1's document are *about* the state design and become false or incomplete once the states are shared. Rewrite each:

  1. **Solution Statement, the `- **Disjoint states.**` bullet.** New text: the piv state set (`piv-drafting`/`piv-draft-review`/`piv-implementing`/`piv-review-pending`/`piv-reviewing`) is **shared by both kinds** and **disjoint from the legacy five**. Consequence: **the decider reads `kind` in exactly two places** — the `queued` intake tier and the `piv-draft-review` tier, the only two states where both kinds sit and the next action differs. Every other tier is determined by state alone (tier 4, the sweep) or by *phase* alone (tier 3 — `investigate`/`fix` are bug-only phase names and `design`/`build` are feature-only, so `phase_at_question` already encodes the kind without a `kind` read). Those two coupling points are what keep coexistence auditable.
  2. **The `headless-protocol.md` task's `## Pipelines and their phase vocabularies` table.** Three rows, not two:

     | pipeline | selected by | phases (`status.json`'s `phase`) | states | lanes |
     |---|---|---|---|---|
     | legacy feature (**retired, inert**) | never dispatched after the feature-fork plan; reachable only by hand-setting a state | `plan`, `replan`, `implement`, `ship` | `planning`, `plan-review`, `building`, `shipping`, `ship-pending` | plan, build, ship |
     | piv — feature | `kind: feature` (or absent) | `design`, `redesign`, `build`, `review` | `piv-drafting`, `piv-draft-review`, `piv-implementing`, `piv-review-pending`, `piv-reviewing` | plan, build, review |
     | piv — bug | `kind: bug` | `investigate`, `re-investigate`, `fix`, `review` | *(the same five)* | plan, build, review |

     Shared states: `queued`, `needs-input`, `ready-to-test`, `failed`, `done`. Restate the invariants: **(a)** the piv state set and the legacy state set are disjoint, so a legacy-state ticket can only ever be claimed by legacy tiers and vice versa; **(b)** `kind` is read in exactly two places; **(c)** phase names are globally unique across all three pipelines, which is what lets `phase_at_question` route tier 3 and what lets `REQUEUE_STATE` be a flat map.
  3. **NOTES → "The one design property that makes this safe: disjoint state sets".** Retitle to reflect the shift and rewrite its three numbered properties: `kind` is read in two places, not one; the *legacy* path gains no new transitions (still true, still checkable by running the unmodified pre-existing tests); and point 3 ("the follow-up plan is unblocked, not entangled") is now resolved — record what the follow-up actually chose, and why sharing beat a third state set: **more coupling, far less surface**, the exact inverse of Phase 1's original trade, and correct now that there are two consumers instead of one.
- **GOTCHA**: Do not weaken the `_issue_lock_free`-before-every-claim rule anywhere. It applies to `piv-draft-review` for **both** kinds, for the same reason Phase 1 records for `rca-review`: the drafting act writes the state several steps before the wrapper releases `lock.issue.<id>`, and claiming inside that window orphans the claim (the ENG-1327 failure).
- **VALIDATE**: `grep -n 'exactly two places\|piv-draft-review\|legacy feature (\*\*retired' /home/coder/coder-packages/docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md`
- **SATISFIES**: AC #1, AC #2

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — `rca_path` → `artifact_path`, `rcaPath` → `artifactPath`

- **IMPLEMENT**: Generalize the ticket field and the decision key, so the shared machinery carries one name for "this ticket's primary durable artifact" regardless of kind. Phase 1 already set this precedent by renaming `status.json`'s `plan_path` → **`artifact_path`**; this extends the same rename to the ticket schema and the decider→wrapper contract.

  Edit sites, by matched text:
  - **`UPDATE autopilot/bin/ap_queue.py`** task, sub-item 4: `a new `"rca_path": None` field alongside `plan_path`` → `a new `"artifact_path": None` field alongside the legacy `plan_path`, with a comment: **the piv fork's artifact — a committed RCA for a bug, a committed implementation plan for a feature — resolved kind-specifically by the decider; `plan_path` stays for the inert legacy path only.**
  - **`CREATE autopilot/tests/test_queue.sh`** task: `a fresh ticket carries `rca_path: null`` → `artifact_path: null`.
  - **`ADD autopilot/bin/ap-decide.py — resolve_rca_path`** task: `entry["rca_path"]` → `entry["artifact_path"]`. **Keep the function named `resolve_rca_path`** — it resolves an RCA specifically; the feature fork gets its own sibling.
  - **`UPDATE autopilot/bin/ap-decide.py — tiers 1/2`** task: `artifact resolve_rca_path, decision key rcaPath` → `decision key artifactPath`.
  - **`ADD piv-investigate-issue — ## Headless mode`** task, sub-item 8's bash block: `--field rca_path=...` → `--field artifact_path=...`; sub-item 9's `re-record `rca_path`` likewise.
  - **`UPDATE autopilot/bin/ap-cycle.sh — dispatch`** task, sub-item 1: `rca_path="$(json_field "$poll_json" ".rcaPath")"` → `artifact_path="$(json_field "$poll_json" ".artifactPath")"`; sub-item 4's `fix)` prompt: `--rca $rca_path` → `--rca $artifact_path`.
  - **`UPDATE autopilot/tests/test_decide.sh`** task, case 3: ``rcaPath` set` → ``artifactPath` set`.
  - **`ADD autopilot/bin/ap-decide.py — resolve_rca_path`** task's own VALIDATE fixture: the dict literal `{'eng_id':'ENG-9','rca_path':None}` → `{'eng_id':'ENG-9','artifact_path':None}`.
  - **TESTING STRATEGY** section's "`rca_path` presence" phrase → "`artifact_path` presence".
  - **`UPDATE autopilot/bin/ap_queue.py`** task — two additional bullets, found by red-teaming this plan (see `ADVERSARIAL REVIEW`), closing a real latent gap that predates this plan but becomes load-bearing once tier 5 dispatches through a `kind`-branched action instead of a hardcoded constant:
    - **`transition()` must validate a written `state` against `STATES` before writing it**, instead of the current bare `entry.update(**fields)`. Reject (or at minimum log loudly and refuse) a `state` value not in `STATES`. One-line-scale fix; makes the entire class of state-name drift this migration is full of — a stale bug-fork name, a typo, a future rename missed in one file — loud instead of silent.
    - **`ticket_kind()` must validate against `KINDS`, not just check truthiness.** Replace `entry.get("kind") or DEFAULT_KIND` with the equivalent of `value = entry.get("kind"); return value if value in KINDS else DEFAULT_KIND`. A present-but-invalid value (`"Bug"`, `"BUG"`, a stray `true`/`1` from a hand-edit or a future bug in `ap queue`'s own parsing) is truthy today and passes through as itself, silently failing every `== "bug"` check and running a bug ticket through the feature-plan path, which has no root-cause diagnosis step. Preserves back-compat: a genuinely *missing* key still defaults to `feature`, so every existing ticket is unaffected — only the present-but-garbage case is newly caught.
- **PATTERN**: Phase 1's own `status.json` generalization (`plan_path` → `artifact_path`, "absolute path to the run's primary durable artifact — a committed plan, a committed RCA, a report — or null"). Use the identical wording for the ticket field so the two layers read as one concept.
- **GOTCHA**: Do **not** rename the **legacy** `plan_path` ticket field or the legacy `planPath` decision key. They belong to the inert legacy path, which stays byte-identical, and `resolve_plan_path` reads `plan_path` directly. Three keys would be worse than two; two is what this leaves: `planPath` (legacy, dead) and `artifactPath` (piv, both kinds).
- **GOTCHA — superseded by the red-team fix above.** An earlier draft of this task said "`transition()` applies `**fields` blindly by design — no validation to add, same as Phase 1's note on `kind`." That is no longer the design: `transition()` gains the `STATES` check described above. Phase 1's original concern (that `transition()` shouldn't validate fields generically, since `ap sessions`' status picker feeds it from `sorted(ap_queue.STATES)` and broad validation would be a new dashboard failure mode) still holds for fields in general — this fix is narrowly scoped to `state` alone, the one field whose value space is a closed, enumerable set with real downstream consumers that assume closure.
- **GOTCHA — the negative-grep VALIDATE below must exclude `resolve_rca_path` itself.** `rca_path` is a literal substring of the function name `resolve_rca_path`, which this task explicitly keeps (it resolves an RCA specifically; the feature fork gets its own sibling `resolve_piv_plan_path`) — a bare `grep 'rca_path\|rcaPath'` will always show hits at every `resolve_rca_path` call site and can never pass as written. Exclude that function name explicitly.
- **VALIDATE**: `grep -n 'rca_path\|rcaPath' /home/coder/coder-packages/docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md | grep -v resolve_rca_path` → expect no hits.
- **SATISFIES**: AC #2, AC #4

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — the three shared skill sections

- **IMPLEMENT — `piv-commit`.** **Not fully kind-agnostic as written**; two of the seven sub-items bake in the bug fork. Amend the `ADD claude/skills/piv-commit/SKILL.md` task:
  - Sub-item 3, `It runs inside the `fix` act, invoked by `piv-implement-issue`'s headless end state` → **it runs inside the build-phase act — `fix` for a bug (invoked by `piv-implement-issue`), `build` for a feature (invoked by `piv-implement`)** — and inherits that session's ENG id and worktree either way.
  - Sub-item 6, `The commit must include the fix, its tests, the RCA (if this is the first commit on the branch), and the fix report` → **the commit must include the implementation, its tests, the approved artifact (the RCA or the plan) if this is the first commit on the branch, and the phase's report.** Keep the sentence that follows verbatim — "Nothing else: an out-of-plan file in the commit becomes an out-of-scope finding in the very next phase's review" — it is kind-agnostic and it is the seed of the scope gate this plan ports into `piv-implement`.
  - Sub-items 1, 2, 4, 5, 7 and both GOTCHAs: **verified already kind-agnostic, no change needed.**
- **IMPLEMENT — `piv-create-pr`.** Amend the `ADD claude/skills/piv-create-pr/SKILL.md` task:
  - Sub-item 4's push line, `push as `git -C <worktree> push -u origin haroun/eng-<id>-fix-<slug>`` → push the **explicit branch name the act's worktree is already on**: `haroun/eng-<id>-<slug>` for a feature, `haroun/eng-<id>-fix-<slug>` for a bug. Both match the profile's only push grant `Bash(git push -u origin haroun/*)`. The rest of that sub-item's reasoning (never `HEAD`; a remote branch name a human can correlate to the ticket) stands verbatim and applies to both.
  - Sub-item 6's body content — replace the single fix-report reference with a **`kind`-branched implementation-report lookup**, and state that this is exactly what `piv-create-pr/SKILL.md:57-59`'s `.claude/reports/<…>-report.md` lookup must become:

    | ticket kind | report path folded into the PR body | approved artifact linked under `## Linked` |
    |---|---|---|
    | bug | `docs/issues/reports/<ENG-ID>-fix-report.md` | the RCA, `docs/issues/issue-<ENG-ID>.md` |
    | feature | `docs/plans/reports/<ENG-ID>-<slug>-report.md` | the plan, `docs/plans/<ENG-ID>-<slug>.md` |

    Both are resolvable the same deterministic way — anchored on the ENG id at a fixed relative path — and **both are committed by `/piv-commit` inside the same act**, so the lookup never races an unwritten file. `<slug>` is the plan file's own slug, so the report name is derivable from the plan path with a suffix, not from a second convention. Keep `Part of ENG-<id>` never `Fixes`/`Closes`/`Resolves` for both.
  - Sub-items 1, 2, 3 (the five-row precondition table), 5, 7, 8 and both GOTCHAs: **verified already kind-agnostic, no change needed.** In particular the `Existing PR already open → DONE-idempotent` row is what makes a retried `build` act safe, exactly as it makes a retried `fix` act safe.
- **IMPLEMENT — `piv-review-pr`.** Amend the `ADD claude/skills/piv-review-pr/SKILL.md` task: its **third GOTCHA** currently reads "`:36-42`'s implementation report at `.claude/reports/*{branch}*` lookup should point at `docs/issues/reports/<ENG-ID>-fix-report.md` for a bug ticket". Replace with the same two-row kind-branched table as above, so the documented-deviation cross-check finds something for either kind. **Everything else in that section — the phase, the required `--issue` token, the preflight, the worktree resolution, the state guard, the `--ports` rule, the entire `babysit-pr` mapping table including the non-blocker auto-apply carve-out and the human-pushed-branch stop, the success end state, and the never-merges statement — is verified already kind-agnostic; no change needed.** Say that explicitly in the amended task so a future reader knows it was checked rather than skipped.
- **PATTERN**: Phase 1's own task voice — an IMPLEMENT bullet per file, a PATTERN, GOTCHAs, one executable VALIDATE.
- **GOTCHA**: `docs/plans/` **is tracked** in the work repo (verified: ~60 committed files) so it exists in any fresh worktree — unlike `docs/issues/`, which Phase 1 correctly flags as needing creation. But `docs/plans/reports/` is new and does not exist in HEAD: create it before writing, same as Phase 1's `docs/issues/` note.
- **VALIDATE**: `grep -n 'docs/plans/reports\|kind-branched\|already kind-agnostic' /home/coder/coder-packages/docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md`
- **SATISFIES**: AC #1, AC #8

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — generalize the two wrapper arms and add the feature dispatch

- **IMPLEMENT**: Two of Phase 1's orchestrator tasks describe arms that must serve both kinds. Amend rather than duplicate:
  - **`UPDATE autopilot/bin/ap-cycle.sh — dispatch`, sub-item 5.** Widen the `fix)` arm to **`fix|build)`**, selecting the prompt inside it (`fix` → `/piv-implement-issue $issue --headless --rca $artifact_path --ports …`; `build` → `/piv-implement --headless --plan $artifact_path --issue $issue --ports …`) and sharing the post-`DONE` block verbatim: `queue_set "$issue" --state piv-review-pending --event "<phase> done, PR open -> review pending"` plus the notify ping. **Reasoning to state in the amended task:** the post-DONE write must be provably identical for both kinds, and duplicating six lines across two arms is exactly the drift generator Phase 1's own `ap-resume.sh`-vs-`ap-cycle.sh` GOTCHA warns about. Keep Phase 1's "there is **no chained review dispatch** here, and why" comment — it now covers both kinds and is the sentence that makes the implement→ship chain unreachable.
  - **`UPDATE autopilot/bin/ap-resume.sh`, sub-item 2.** Widen the new `fix)` arm to **`fix|build)`**, writing the same `piv-review-pending` state and ping. **The gap Phase 1's audit found for `fix` applies identically to `build`, by exactly the same reasoning**: at park time the wrapper set the ticket to `needs-input`, not `piv-implementing`; the skill never writes its own terminal ticket state (that write is wrapper-owned); a *resumed* act's DONE is reconciled here and nowhere else; and without an arm the ticket strands at `needs-input` forever — no tier claims `needs-input` without a `feedback` field, and `needs-input` is not in `sweep_stale`'s tuple. Also widen the `plan|replan` → `investigate|re-investigate` DONE branch to include **`design|redesign`**, and the `ship|review` branch is already correct for both.
  - Both tasks' `REQUEUE_STATE` / requeue-map sub-items gain the feature phases: `design`/`redesign` → `queued`, `build` → `piv-draft-review`, alongside Phase 1's bug rows. **The two maps must stay identical across `ap-cycle.sh` and `ap-runs.py`** — Phase 1 already mandates a cross-reference comment in both; extend it.
  - **`UPDATE autopilot/bin/ap-cycle.sh — reconcile` task's external-failure requeue `case "$final_phase"` — a catch-all fix found by red-teaming this plan (see `ADVERSARIAL REVIEW`).** An unmatched `$final_phase` leaves `requeue_state` empty, and the write guard silently skips the queue write entirely — no state change, no diagnostic, on top of whatever the act's own FAILED/NEEDS_HUMAN handling already did. Add a final `*)` arm: on an unmatched phase, write `needs-input` with `question: "unrecognized phase '<phase>' in the external-failure requeue map — routing unknown, needs a human decision"`, rather than silently skipping the write. Same fail-closed-and-loud shape as the lane-lock catch-all (the `ap-cycle.sh` dispatch task's new sub-item 8) and the tier-3 fallback fix, all three mirroring `ap retry`'s existing `REQUEUE_STATE.get(phase)`-miss pattern.
  - **`UPDATE autopilot/bin/ap-resume.sh` task's DONE branch — same catch-all gap.** Its `if/elif` chain over `$phase` has no final `else`. An unrecognized phase on a *resumed* act's DONE currently produces silent no-op: no state write, no notify, no window teardown. Add an `else` arm with the same `needs-input` + diagnostic-question treatment as above.
- **GOTCHA**: Do not touch `ap-resume.sh`'s `implement)` chained-ship branch (`:431-468`) or its `act_build_${acquired_lock_file##*.}_…` window-name string trick. Both become unreachable and both stay exactly as they are — the fragile trick is one more reason not to generalize it.
- **GOTCHA**: `run_claude` prepends `--run-dir $AP_RUN_DIR` to its prompt argument; every new prompt is a single argument and must not contain `--run-dir` itself.
- **VALIDATE**: `grep -n 'fix|build\|design|redesign' /home/coder/coder-packages/docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md`
- **SATISFIES**: AC #5, AC #6

### UPDATE `docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md` — the `## AMENDMENTS` entry

- **IMPLEMENT**: Replace the placeholder in `## AMENDMENTS` with a dated entry:

```markdown
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
  `ap-resume.sh`'s `fix)` arms widen to `fix|build)` so the shared review-pending write is literally
  shared. Made **before this plan was executed**, so no live ticket was in any renamed state.
```

- **GOTCHA**: `## AMENDMENTS` is append-only and its header says "Leave empty at creation; newest entry at the bottom." This is the first entry — replace the angle-bracket placeholder line, do not append after it.
- **VALIDATE**: `sed -n '/^## AMENDMENTS/,$p' /home/coder/coder-packages/docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md | grep -c '2026-09-03'`
- **SATISFIES**: AC #1

*(Two notes before the remaining tasks: there is **no standalone `ap_queue.py` task** in this plan — the generalized `STATES` and the `artifact_path` field are delivered by amending Phase 1's own `ap_queue.py` task, above, because Phase 1 is what actually writes that file. And there is **no `ap-env.sh` task at all** — this plan adds no lane, no slot variable and no port range, so `ap-env.sh` is untouched.)*

### ADD `claude/skills/piv-plan-implementation/SKILL.md` — step 7: the conditional red-team gate

- **IMPLEMENT**: A new numbered step in the Planning Process, **after Phase 5c** (the Codex second draft) and **before `## Output Format`**, titled `### Phase 5d: Red-team the plan — ONLY when it touches a guard`. Mirror `implement-issue/SKILL.md:354-399` exactly:

  Bold **Conditional. Skip it and say so unless the trigger below fires** — an unconditional extra critic pass on every ticket is the review-swarm this pipeline deliberately avoids, and it is not free.

  **Trigger — fires when the plan changes the behaviour of any of** (verbatim from `implement-issue/SKILL.md:360-365`): a verifier or postcondition, a validator, a dispatcher/entry gate, a cap or budget check, a permission or entitlement check, a dedupe/idempotency key, a retry or fallback branch, or a default that decides whether work happens at all. Classify from the plan's own `New Files to Create` / `STEP-BY-STEP TASKS` file list and its `IMPLEMENTATION PLAN` phases; **when genuinely uncertain, run it.**

  **Why this exists and Phase 5b does not cover it.** `plan-critic` asks *"are the plan's claims true?"*. That is a different question from *"what does this change now let through?"*, and a plan can pass the first while failing the second completely — the ENG-1406 case recorded at `implement-issue/SKILL.md:370-377`, where every claim was independently verified and correct and the plan was still wrong. Phase 5c (Codex's second draft) does not cover it either: Codex proposes an *alternative approach*, it does not attack the chosen one's blast radius.

  Dispatch a **fresh** `Agent` carrying `/red-team`'s rubric (model `fable` or `opus`, effort matching Phase 1's Estimated Complexity), given: the change stated as a behaviour delta (`/red-team` §0: *"after this change, X will happen where Y happened before"*), the guard's current code and tests, and **explicitly not the plan's own argument for why the change is right**. Require back the same five items `implement-issue`'s step 7b requires: must-stay-fatal list, discriminator attack, replay, blast radius (enumerated call sites, not an estimate), already-solved check.

  Fold findings into the plan's new `## Adversarial review` section (next task), **including a recorded non-firing trigger, so every skip is auditable**. Verdict routing: `do not ship as specified` → a `DO NOT IMPLEMENT`-equivalent, rework before handing the plan off (headless mapping in the headless section). `ship with the named additions` → fold the additions into the affected tasks and proceed.

  **No `/challenge` step here, and state why in one sentence in the skill**: `/challenge` attacks the provenance of a measurement an existing conclusion rests on — an instrument, a window, a population, a proxy. A forward-looking implementation plan has no root-cause evidence chain of that shape; its factual claims are `file:line` assertions about current code, which Phase 5b's `plan-critic` already re-derives against the real repo, and its forward claims are exactly what `/red-team` attacks. Phase 1's bug fork has a `/challenge` step because an RCA's 5-Whys chain genuinely can rest on a dashboard figure; a plan's cannot.
- **PATTERN**: `implement-issue/SKILL.md:354-399` — copy its structure exactly, and Phase 1's `piv-investigate-issue` step 7 for how that structure was already adapted into a `piv-*` skill.
- **GOTCHA**: `/red-team`'s §3 replay ("do not reason about the change's reach, compute it") usually **cannot run headlessly** — the `dontAsk` profile allows no database read tools and no piped queries. Instruct the sub-agent explicitly: if the historical rows cannot be obtained, **that gap is itself the finding** and must be reported as such, never reasoned around. Same wording `implement-issue/SKILL.md:388-390` already uses.
- **GOTCHA**: This is a sub-agent inside the design act, not a separate act. It writes no `status.json` and no queue entry. `red-team`'s own headless section (added by Phase 1) already states this from its side.
- **GOTCHA**: Number it `5d` and place it **after** 5c, not before: 5c's second draft can surface a materially different approach that gets grafted into the plan, and red-teaming a plan that is about to be revised wastes the pass. Same ordering argument Phase 1 applied to running `/challenge` before `/red-team`.
- **VALIDATE**: `grep -n 'Phase 5d\|do not ship as specified\|no /challenge step\|Conditional' /home/coder/coder-packages/claude/skills/piv-plan-implementation/SKILL.md`
- **SATISFIES**: AC #9, AC #10

### ADD `claude/skills/piv-plan-implementation/SKILL.md` — `## Adversarial review` in the Phase 5 template

- **IMPLEMENT**: Inside the Phase 5 plan template, between `## NOTES (open canvas)` and `## PLAN AUDIT` — so the three critic sections (`Adversarial review`, `PLAN AUDIT`, `APPROACH COMPARISON`) sit together and a reader finds every independent check in one place:

```markdown
## ADVERSARIAL REVIEW — red-team, guard-touching plans only

<Filled by Phase 5d. **Trigger**: fired / did not fire — <which guard class this plan changes, or
why none applies>. A did-not-fire record is mandatory: a missing section is indistinguishable from a
skipped step.

If fired: verdict (`ship` / `ship with the named additions` / `do not ship as specified`) ·
must-stay-fatal list with how each is preserved · discriminator attack · replay result (or "rows
unobtainable — recorded as a finding") · blast radius, enumerated call sites · already-solved check ·
what changed in the tasks above as a result.>
```

- **PATTERN**: the template's existing `## PLAN AUDIT` / `## APPROACH COMPARISON` placeholder style (angle-bracket instructions inside the section, filled by the phase that runs), and `implement-issue/SKILL.md:396-397`'s "record the trigger decision when it did not fire, so the skip is auditable."
- **GOTCHA**: This section is part of the **template the skill emits**, not part of the skill's own prose — it goes inside the fenced ```markdown block that runs from `# Feature: <feature-name>` to the `## AMENDMENTS` example line. Adding it outside that fence makes it a section of the *skill file* instead of every plan the skill writes.
- **GOTCHA**: Update the skill's `## Report` section (`:645-658`) to name Phase 5d's outcome alongside 5b's verdict and 5c's, so the final report surfaces all three.
- **VALIDATE**: `grep -n 'ADVERSARIAL REVIEW' /home/coder/coder-packages/claude/skills/piv-plan-implementation/SKILL.md`
- **SATISFIES**: AC #9

### UPDATE `claude/skills/piv-plan-implementation/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: New section at the end of the file. Contents, in order:

  1. **The pointer sentence**, verbatim in shape from `implement-issue/SKILL.md:1139-1142`, naming `headless-protocol.md`. Nothing about `status.json`, `dontAsk` or ask→fallback mechanics is restated.
  2. **Phase**: `design` (or `redesign` when `--feedback` is present). `phase_at_question: "design"` on every `NEEDS_HUMAN`. Invoked as `/piv-plan-implementation ENG-<id> --headless [--feedback '<text>'] --run-dir <d>`.
  3. **Input is always an existing Linear issue id.** The free-form-description branch of `## Resolve the input first` is interactive-only. A headless invocation whose argument does not match `ENG-\d+`, or whose Linear fetch returns nothing, is `FAILED` with `detail` naming what was passed — never a plan drafted from a bare id.
  4. **The worktree + branch sections are mandatory, not optional.** `## Multi-repo worktree setup` (`:27-45`) and `## Kata mirror` (`:47-64`) each end with a "skip entirely for a free-form/no-ticket plan" escape; **that escape never applies headlessly**, because headless input is always a Linear id. Run both unconditionally, `--feedback` re-runs included (both are harmless no-ops when repeated). This section is materially lighter than Phase 1's equivalent for `piv-investigate-issue` for one reason worth stating: that skill had **no** branch discipline at all and the mandate had to be invented; this one already has the right one — `wt-eng<id>-<suffix>` worktrees off the right base per repo (`dev` for root/`backend/`/`frontend/`, `main` for `assistants/`/`observability/`, confirmed per repo, never assumed), plan written *inside* the root worktree, and `work.branch haroun/eng-<id>-<slug>` recorded at `:57`. Headless only removes the opt-out and adds the branch cut: create/checkout **`haroun/eng-<id>-<slug>`** in the root worktree before writing anything, so the plan commit is on the branch the build act will reuse and rides into that branch's PR — the skill's own `piv-implement:22-24` warning ("a plan committed on the base branch won't be in this branch's PR") is the reason.

     **Never work in the main checkout**, for Phase 1's three verified reasons, unchanged: it is permanently dirty and on an unrelated branch, so every downstream dirty-tree and branch heuristic misfires; `AP_BUILD_SLOTS > 1` means two acts must never share a checkout; and the `dontAsk` profile only permits `git push -u origin haroun/*`.
  5. **Linear claim + kata mirror, first thing**: claim (`assignee: me`, `state: In Progress`) via `mcp__linear-server__save_issue`, then `:47-64`'s `kata search "ENG-<id>" --agent` / create with `--idempotency-key`, `kata meta set <ref> work.attention ok`, and `work.branch haroun/eng-<id>-<slug>` once the branch is cut. This is the only place a feature ticket's Linear claim can happen — `ap-decide.py` has no Linear credential. Mirrors Phase 1's `piv-investigate-issue` pattern exactly, including which kata calls happen where.
  6. **Ask-point mapping table:**

     | ask point | headless resolution | recorded as |
     |---|---|---|
     | **Phase 2's clarifying GATE** (`:152-178`) — "post the questions, then stop. End the turn and wait" | **The skill already has a documented headless-safe fallback and it is used verbatim** (`:176-178`): nobody answers, which is the `If they decline` branch — honour it, and **name every guess**. Each unanswered item becomes an `Assumed — <the assumption>, confirm before execution` line in the plan's `OPEN QUESTIONS / ASSUMPTIONS`, and each affected task carries a `**GOTCHA**` naming it. Never guess silently, and never ask-and-answer in the same breath as if a human had replied. **Not a `NEEDS_HUMAN`** — see the note below the table. **Also override the skill's own interactive kata rule for this specific gate**: `:58-60` sets `kata meta set <ref> work.attention needs-human` for a blocking Phase-2 question, but headless never parks here — keep `work.attention ok` throughout, since the assumptions proceed straight into the plan rather than stopping the act. Applying the interactive kata rule unmodified would leave the ticket's kata signal falsely stuck at `needs-human` while the act itself carries on normally to `piv-draft-review`. | the plan's own `OPEN QUESTIONS / ASSUMPTIONS` section, which becomes the review agenda at `piv-draft-review` |
     | Thin/vague answer handling (`:173-174`) | unreachable headlessly (no answers arrive at all) — the decline branch above covers the whole gate | n/a |
     | Ticket, epic and architecture genuinely settle everything (`:169-171`) | already headless-shaped: say so in one line in the plan and proceed | the plan's one-line statement |
     | Phase 3 external research (`:183-206`) unavailable — `WebSearch` denied or a fetch fails | documented default: **note the gap in the plan and continue**, never stall. Same shape as Phase 1's Codex-denial rule. `WebSearch` is added to the allow list by this plan's permissions task; treat a denial as evidence the profile drifted, not as a failure | `detail` + a line in the plan's `Relevant Documentation` |
     | **Phase 5b `plan-critic` returns `DO NOT IMPLEMENT`** (`:537-539`) | the skill's own default: **rework once and re-audit**. If the second audit is still `DO NOT IMPLEMENT` → **`NEEDS_HUMAN`**. Never paper over it, never proceed anyway | `question` = the verdict plus the single most load-bearing finding; the full audit lives in the plan's `PLAN AUDIT`; kata `work.attention needs-human` |
     | Phase 5c Codex second draft fails / `codex_unavailable` / denied (`:550-592`) | documented default: note it in `APPROACH COMPARISON` ("second draft unavailable — <reason>") and proceed. A bonus check, not a gate — same as Phase 1's treatment of the investigate act's Codex corroboration | `APPROACH COMPARISON` + `detail` |
     | **Phase 5d red-team `do not ship as specified`** | **`NEEDS_HUMAN`** — never a silent override, exactly as Phase 1 maps `piv-investigate-issue`'s step-7 verdicts | `question` = the verdict plus the must-stay-fatal case the plan does not preserve; findings live in `ADVERSARIAL REVIEW`; kata `needs-human` |
     | `/worktree-create` fails, or the base branch cannot be confirmed for a repo | `FAILED`, `detail` = the failing command and its stderr. The remedy is git work at a terminal, which the `ap reply` channel cannot express | `detail` |
     | Linear ticket has an empty body **and** no comments **and** no parent epic | `FAILED`, `detail: "nothing to plan from"`. This is the one line between "proceed with `Assumed —` lines" and "draft a guess pyramid": *some* information → proceed; *zero* → fail fast | `detail` |

  7. **Does a `piv-plan-implementation` run ever legitimately reach `NEEDS_HUMAN`? Yes — but never from the clarifying gate.** State this explicitly, because it is the question a reader will arrive with. Exactly two park points exist: a twice-`DO NOT IMPLEMENT` audit, and a `do not ship as specified` red-team verdict. Both are *a critic on a different model lineage saying this plan should not be built*, which is precisely the class of judgment a human owns.

     The clarifying gate is **not** one of them, and the reason is structural rather than a preference: the questions the skill would have asked interactively do not disappear — they become `Assumed —` lines in the plan's own `OPEN QUESTIONS / ASSUMPTIONS` section, and that plan then goes to `piv-draft-review`, where a human reads it and can `ap approve` or `ap reply '<answers>'` before **a single line of code is written**. The approval gate *is* the clarifying interview, deferred by one hop and made asynchronous. Parking at the gate instead would spend a `needs-input` park to ask the same questions the approval gate is about to surface anyway, and would cost a whole re-dispatch to resume. State the one condition this rests on: **it is safe only because the `piv-draft-review` gate exists.** If a future change ever auto-approves plans by default, this mapping must be revisited.
  8. **Phase 5b and 5c run headlessly, unchanged.** Both are read-only sub-agent dispatches with no human ask point of their own — 5b is an `Agent(subagent_type: "plan-critic", model: "fable")` call; 5c is `node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo> --lane plan-debate --read-only`, which writes nothing. Keep the `fable` model override on 5b (running the audit on the family that drafted the plan defeats it) and keep 5c's read-only mode. Two headless-specific rules: **(a)** run 5c as a **blocking foreground** command despite `codex-delegate`'s usual background advice — backgrounding across a turn boundary is fatal under the protocol's never-background rule, and 5c at `effort: max` can run 10-20 minutes; **(b)** `Bash(node *)` is required and is added by Phase 1's permissions task — a denial means "second draft unavailable", not a failure.
  9. **Plan output path — headless overrides `## Output Format`.** `.claude/plans/{kebab-case-name}.md` (`:594-601`) is interactive-only. Headless writes **`docs/plans/<ENG-ID>-<slug>.md`** in the root worktree, e.g. `docs/plans/ENG-1400-insights-date-filter.md`. Four reasons, all verifiable, and worth stating in the skill because each is a trap:
     - **`.claude/plans/` is untracked in the work repo** (verified: `git status --porcelain .claude` prints `?? .claude/plans/`). Writing there creates exactly the dirty-tree condition `piv-create-pr`'s "Uncommitted changes → STOP" precondition fires on, two phases later. This is the same trap Phase 1 found for `.claude/reports/` and solved the same way.
     - **The plan must be committed anyway.** The build act is a different session, potentially hours later, in a different process; it reads the plan from disk. An uncommitted plan is unreadable to it and leaves the design act's worktree dirty.
     - **`docs/plans/` is this repo's real convention and is tracked** (verified: ~60 committed files, and it is where both this plan and Phase 1 live). It therefore exists in every fresh worktree, needing no `mkdir`.
     - **ENG-id-anchored-at-position-zero makes it deterministically resolvable**, which is what `ap-decide.py`'s new resolver needs and what keeps it out of `resolve_plan_path`'s substring hazard.

     Note the deliberate divergence: the directory's existing files are date-prefixed (`YYYY-MM-DD-<slug>.md`). Headless plans are **not**, so that (a) a resolver can anchor on `^<ENG-ID>-` with a trailing hyphen — which is what makes `ENG-123` not match `ENG-1234-foo.md` — and (b) a piv plan is distinguishable from a legacy `implement-issue` plan for the same ticket by filename shape alone, which matters during the coexistence window. Interactive runs keep `.claude/plans/`; nothing about the interactive contract changes.
  10. **Commit the plan before the queue write**, on the ticket's branch in the root worktree. Same discipline the legacy plan phase already has (`implement-issue/SKILL.md:1202-1204`) and Phase 1's investigate act mirrors.
  11. **End state**: after the commit, one write —
      ```bash
      python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state piv-draft-review \
        --field artifact_path=/absolute/path/to/docs/plans/<ENG-ID>-<slug>.md \
        --event "plan ready for review"
      ```
      then `status.json` with `status: DONE`, `phase: "design"`, `artifact_path` = the plan path, `detail` = the Phase 5b verdict + whether 5c ran + whether 5d fired + the confidence score. Carry Phase 1's emphatic warning verbatim in shape: **without this write the ticket never leaves `piv-drafting` and the pipeline stalls after every plan** — do not skip it, and do not reorder it before the commit lands.
  12. **`--feedback '<text>'`**: treat as the human's answers to the plan's `OPEN QUESTIONS / ASSUMPTIONS` and/or a change of direction — not a mechanical correction. Revise the plan **in place** (same file, same branch, a new commit), convert every now-answered `Assumed —` line into a settled decision, and **re-run Phase 5d's trigger against the revision** — a revised approach can newly touch a guard. Re-run 5b if the revision changed any task's file list. Then re-record `artifact_path` and write `DONE` as above. Phase is `redesign`.
- **PATTERN**: `implement-issue/SKILL.md:1160-1231` (`--phase plan`) — structurally a template: input rule, claim + kata, ask table, artifact commit, end-state write, `--feedback` handling. And Phase 1's `piv-investigate-issue` headless section for how that template was already adapted into a `piv-*` skill.
- **GOTCHA**: `$ARGUMENTS` under a slash invocation is the **whole** argument string (`ENG-1400 --headless --run-dir /x`), not just the ticket id. The `## Resolve the input first` section must extract the `ENG-\d+` token rather than treating `$ARGUMENTS` as one opaque input. Same hazard `piv-implement`'s `--plan` has, below.
- **GOTCHA**: Phase 4 dispatches `Agent(subagent_type: "Plan", model: "opus", effort: "high")` and the act's own pinned model is `opus` — the sub-agent dispatch is unaffected by the act's model pin and stays as written.
- **GOTCHA**: The act runs on the **plan lane with no ports**. This skill starts no dev servers and must not; if a future revision adds one, it needs the `--ports` treatment `piv-implement` gets below, and the plan lane has no port pair to give it.
- **GOTCHA**: `mcp__linear-server__save_comment` is not on the allow list — this skill's `## Report` step (`:656-658`) suggests a kata comment, which is fine (`Bash(kata *)` is allowed), but **never** a Linear comment. Phase 1's Linear-footprint rule applies unchanged.
- **VALIDATE**: `grep -n 'Headless mode\|piv-draft-review\|docs/plans/<ENG-ID>\|Assumed —\|haroun/eng-' /home/coder/coder-packages/claude/skills/piv-plan-implementation/SKILL.md`
- **SATISFIES**: AC #7, AC #9, AC #10, AC #11

### UPDATE `claude/skills/piv-implement/SKILL.md` — `## Headless mode (--headless)`

- **IMPLEMENT**: New section at the end. Contents:

  1. The pointer sentence.
  2. **Phase**: `build`. `phase_at_question: "build"`. Invoked as `/piv-implement --headless --plan <path> --issue ENG-<id> --ports fe=<n>,be=<m> --run-dir <d>`.
     - **`--plan <path>` is always explicit.** A headless invocation without it is `FAILED`, `detail: "headless requires an explicit plan path"`, **no queue write** — mirroring `piv-implement-issue`'s `--rca` requirement and `implement-issue/SKILL.md:1233-1239` exactly. The skill's interactive `Read plan file: $ARGUMENTS` contract (`:11`) does not survive headlessly: `$ARGUMENTS` is the full flag string, so the skill must **parse `--plan` out of it**, never treat `$ARGUMENTS` as a bare path.
     - **`--issue ENG-<id>` is required.** This skill's own arguments carry a plan, not a ticket, and every queue write needs the ENG id — the identical situation Phase 1 already solved for `piv-review-pr` with the same headless-only token. It is therefore an **inherited convention, not a new flag**. The plan's filename encodes the id (`docs/plans/<ENG-ID>-<slug>.md`) and should be cross-checked against `--issue`; a mismatch is `FAILED`.
  3. **This one act runs three skills.** After this skill's own steps complete, the same session runs **`/piv-commit`** and then **`/piv-create-pr`**, and only then writes `status.json`. Same rationale Phase 1 states for the `fix` act: neither has a human-judgment ask point (`piv-commit` has none at all; `piv-create-pr`'s preconditions are deterministic fail-fast checks), so giving each its own act would add two dispatches, two states and two park points for zero decision value.
  4. **Re-entry must be idempotent** — a retried `build` act (external-failure requeue, or `ap retry`) re-enters from `piv-draft-review`. Before implementing anything: if the ticket's branch already exists and already carries a commit whose message contains `Part of ENG-<id>`, **skip to `/piv-create-pr`** rather than re-implementing; `piv-create-pr`'s "existing PR already open → print the URL" precondition is then a `DONE`-idempotent success, not a failure. Word-for-word the same rule Phase 1 gives `piv-implement-issue`, and for the same reason: without it a retry re-implements work that already landed.
  5. **Ask-point mapping table:**

     | ask point | headless resolution | recorded as |
     |---|---|---|
     | **Dirty base branch — `On the base branch with uncommitted changes → STOP: commit or stash first`** (`:46`) — *a bare stop with no stated default* | **`FAILED`**, `detail` = the `git status -sb` output. Reasoning stated in the section, identical to Phase 1's call for `piv-implement-issue:66`: auto-choosing commit-or-stash silently mutates a human's uncommitted work, the one class of action this protocol exists to prevent; and `NEEDS_HUMAN` is the wrong shape because the remedy is git work at a terminal, which the `ap reply` channel cannot express — it would park a tmux window indefinitely. `FAILED` means "an error stopped the run; the wrapper decides whether to retry", and `ap retry` recovers it once the tree is clean. Cost named honestly: `FAILED` increments `fail_count` and can auto-pause after two — which, given the worktree mandate, is correct, because a dirty tree here means a dirty *worktree*. | `detail` |
     | **Branch selection heuristics** (`:41-48`) — `On the base branch, clean → git checkout -b feature/<plan-slug>` | **overridden entirely**: reuse the worktree and branch the design act created (`haroun/eng-<id>-<slug>`); if missing, create it the same way rather than falling through to the interactive heuristics. **Never `feature/<plan-slug>`** — it does not match `Bash(git push -u origin haroun/*)` and would be denied at the last step of the act, the exact trap Phase 1 catalogued for `fix/issue-<id>-<slug>`. | `history` event on a re-create |
     | **Dirty reused worktree** (`:37-39`) — `uncommitted content there is a prior run's unfinished work, not junk — stop and ask rather than recreating it` | **`FAILED`**, `detail` = `git -C <worktree> status --porcelain`. Same reasoning as the row above; the skill's own instinct (don't destroy it) is right, and `FAILED` is the shape that preserves it. Note the interaction with the idempotency rule: a worktree that is *clean* but whose branch carries a `Part of ENG-<id>` commit is the **normal** retry case and takes the skip-to-create-pr path, not this one. | `detail` |
     | **Stale worktree** (`:39`) — `rev-list --count HEAD..origin/dev must be 0 after a fetch && rebase` | documented default: run the `fetch && rebase`. A **rebase conflict** → `FAILED`, `detail` = the conflicting file list (terminal git work, not an `ap reply` answer). A clean rebase → proceed, no record needed. | `detail` on conflict |
     | **Escalation ladder** (`:77-85`) — a task's own report says the spec is wrong, a referenced hook/field doesn't exist, or the change doesn't fit | **Walk the skill's own two-pronged fallback in order, then park.** (i) Fix it yourself with the plan in hand. (ii) If that does not resolve it, get the independent read-only diagnosis: `node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo> --lane review-debate --read-only`, blocking foreground, brief naming what's stuck / what was tried / what's unclear. (iii) If the diagnosis does not unblock it → **`NEEDS_HUMAN`**. This is the feature fork's analogue of the bug fork's drift-check park, and it is this skill's primary park point. **Never let `implementer` improvise past it** — that instruction is the whole point of the ladder and it survives headlessly unchanged. | `question` = the blocker, what was tried, and Codex's read verbatim; kata `needs-human` + `work.attention_msg` |
     | **Validation loop** (`:176-179`) — `Fix the issue / Re-run / Continue only when it passes` | **bounded**: after **two** full failing cycles → `NEEDS_HUMAN` with the failing command and its output. Unbounded headlessly is an act that burns a build slot until the harness kills it. Mirrors Phase 1's identical bound for `piv-implement-issue:171-175`. | `question` on escalation |
     | Codex adversarial test pass (`:125-166`) | unchanged: a bonus check. `status: failed` / `codex_unavailable` / permission-denied → note in `detail` and move on. A genuine failing test means the implementation is incomplete → fix it and keep the test, still inside this act. `touchedFiles` wider than the one test file is scope creep: discard and re-dispatch tighter, exactly as `:159-161` says. | `detail` |
     | **Scope gate** — a changed file outside the plan's own task file list | **`NEEDS_HUMAN`**, the file list quoted in `question`. **Ported from `implement-issue/SKILL.md:1269`**, not invented: the legacy feature path has had this gate headlessly since it existed, and dropping it in the cutover would be a silent regression. It is also the enforcement of `piv-commit`'s own "nothing else — an out-of-plan file becomes an out-of-scope finding in the very next phase's review". | `question` |
     | **Secrets gate** — a secret-shaped string in the diff, or a semantic rebase conflict | **`NEEDS_HUMAN`**, the finding or conflicting file list quoted. **Never push past either.** Ported from `implement-issue/SKILL.md:1271-1274`. | `question` |
     | **Report `Status: PARTIAL`** (`:200`) — the act's own report says it did not finish | run **`/piv-commit`** so nothing is lost and the tree is left clean, then **`NEEDS_HUMAN`** — do **not** run `/piv-create-pr`. A half-implemented plan should not become an open PR silently; whether to ship the partial or re-plan is the human's call. | `question` = the unfinished task list; `detail` = the commit SHA |
     | Kata calls (`:13-20`) | best-effort, unchanged: errors other than "no match" are noted and never a reason to stop. Set `work.attention stuck|needs-human` + a one-line `work.attention_msg` on every park, per `:17-19`. | kata meta |

  6. **Report artifact path — headless overrides `.claude/reports/`.** Write to **`docs/plans/reports/<ENG-ID>-<slug>-report.md`** in the worktree, `<slug>` being the plan file's own slug, **committed by `/piv-commit` as part of the implementation commit.** This needed checking rather than copying Phase 1's answer, and the check confirms the same trap applies: **`git status --porcelain .claude` in the work repo prints `?? .claude/reports/`** — untracked, not gitignored — so a report written there is an uncommitted file that trips `piv-create-pr`'s own "Uncommitted changes → STOP" precondition at the end of this very act. Two further reasons it must be in-repo and committed: it is the reviewer's record of deviations and validation, which `piv-create-pr:57-59` and `piv-review-pr:34-38` both look for and fold into the PR body and the deviation cross-check; and the *next* act (`review`) is a different session that reads it from disk. Its absolute path goes in `status.json`'s `detail`. **Create `docs/plans/reports/` before writing** — `docs/plans/` is tracked and exists in a fresh worktree, but `reports/` does not.
  7. **`--ports fe=<n>,be=<m>`**: this skill starts no dev servers of its own, but step 4 runs "ALL validation commands from the plan in order", and a plan's Level 4 Manual Validation legitimately can. If any command starts the worktree servers: bind **exactly** those two ports (never the baseline 5173/8000), start the worktree backend with `BACKEND_CORS_ORIGINS` set to a JSON list containing `http://localhost:<feport>` — this **replaces**, not extends, the default allowlist — and **stop them before writing `DONE` *or* `NEEDS_HUMAN`** (a slot freed at park time can be handed to a fresh act whose ports would collide). Verify with `ss -ltnp` before and after. In practice these ports are usually unused, exactly as Phase 1 notes for the review lane; they are provisioned for isolation-safety and consistency, and should not be documented as load-bearing for this lane the way they genuinely are for a legacy `implement` act's browser QA.
  8. **Rebase onto fresh base before opening the PR.** Between the last gate and `/piv-create-pr`: `git -C <worktree> fetch` then `git -C <worktree> rebase origin/<base>`; if the rebase moved anything, **re-run the plan's validation commands** before proceeding; a conflict is `FAILED` per the table. **Stated explicitly because it is a property this cutover would otherwise lose**: the legacy chain got "rebased onto the latest dev and locally gate-clean" from `/ship-work`, which no longer runs. `piv-review-pr` checks the PR out and runs the suite but does **not** rebase. Recovering it here costs two commands inside an act that already has the worktree open.
  9. **End state**: implement → tests → validate → scope/secrets gates → rebase → **`/piv-commit`** → **`/piv-create-pr`** → `status.json` with `status: DONE`, `phase: "build"`, `artifact_path` = **the plan path, unchanged from intake**, `pr_urls` filled with every opened PR URL, `detail` = the report path + the commit SHA + the validation summary. Record on the ticket in one write: `--field pr_urls='["<url>"]' --event "implementation committed <sha>, PR open"`. **Do not change the ticket's `state`** — it stays `piv-implementing`; the wrapper swaps it to `piv-review-pending` after seeing this `DONE`. Same wrapper-owns-the-swap rule Phase 1 states for `fix` and the legacy path states for `implement`.
  10. **Pushing and opening PRs is pre-approved headlessly; nothing else loosens.** Never `main`, never a direct push to `dev`, never a merge call, never a Linear comment, never a Linear state beyond the claim.
- **PATTERN**: Phase 1's `ADD claude/skills/piv-implement-issue/SKILL.md — ## Headless mode` task, which this mirrors section-for-section (phase, explicit-artifact requirement, three-skills-one-act, idempotent re-entry, ask table, report path, ports, end state); and `implement-issue/SKILL.md:1233-1310` for the scope/secrets/ports/end-state wording being ported.
- **GOTCHA**: `git checkout -b` / `git switch` / `git rev-parse` / `git symbolic-ref` all already pass under the current profile **via the `Bash(git -C *)` allowance** — verified by reading `autopilot/settings/autopilot.json:19`. Use the `-C <worktree>` form throughout; do not assume a bare form is granted.
- **GOTCHA**: The multi-repo rule at `:35-36` — one repo at a time in dependency order, sequential within a repo, independent repos concurrent — survives headlessly unchanged, and every repo's PR URL goes into `pr_urls`.
- **GOTCHA**: This act's pinned model is `sonnet` (`act_model`'s `build)` arm), matching the skill's own "sonnet, medium effort by default" execution tier at `:52-58`. The `implementer` and `codex-feature` sub-agent dispatches are unaffected by the act's pin.
- **VALIDATE**: `grep -n 'Headless mode\|--plan\|docs/plans/reports\|idempotent\|scope gate\|FAILED' /home/coder/coder-packages/claude/skills/piv-implement/SKILL.md`
- **SATISFIES**: AC #7, AC #8, AC #11, AC #12

### ADD `autopilot/bin/ap-decide.py` — `resolve_piv_plan_path`

- **IMPLEMENT**: New function next to `resolve_rca_path` (itself next to `resolve_plan_path`):
  `entry["artifact_path"]` if it still exists on disk; else search `work_repo/wt-*-root/docs/plans/` then `work_repo/docs/plans/` for a basename that, **lowercased**, either equals `<eng-id>.md` or **starts with `<eng-id>-`** (the trailing hyphen is load-bearing); newest by mtime among ties; else `None`.
- **PATTERN**: `resolve_rca_path` as Phase 1 specifies it — same two-tier worktree-then-root search, same mtime tie-break, same `None` contract, same exact-match-first discipline.
- **IMPORTS**: `glob`, `os` (already imported).
- **GOTCHA**: **Do not reuse `resolve_plan_path`.** It resolves the *legacy* `implement-issue` plan location (`docs/plans/*<eng-lower>*.md`) and carries the known substring hazard Phase 1 declined to fix: `*eng-123*` also matches `eng-1234-foo.md`, and with the mtime sort a newer unrelated ticket's plan can win. Anchoring on `^<eng-id>-` kills it — `eng-1234-foo.md` does not start with `eng-123-` because the character after `123` is `4`, not `-`. Add a comment saying so, and that fixing the legacy version stays out of scope.
- **GOTCHA**: Anchoring also gives a second, load-bearing property: a legacy plan (`YYYY-MM-DD-eng-<id>-<slug>.md`, date-prefixed) **cannot** be resolved by this function, and a piv plan (`ENG-<id>-<slug>.md`) is a different filename shape from any legacy one. The two forks' artifacts are distinguishable by name alone, which is what makes the coexistence window safe.
- **GOTCHA**: Compare **lowercased** basenames throughout. Real filenames in `docs/plans/` are mixed-case (`2026-06-12-ENG-461-orchestration-conformance.md` exists); the headless convention writes uppercase `ENG-`; never assume the case.
- **VALIDATE**: `cd /home/coder/coder-packages/autopilot/bin && python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('d','ap-decide.py'); m=importlib.util.module_from_spec(s); sys.modules['d']=m; s.loader.exec_module(m); print(m.resolve_piv_plan_path({'eng_id':'ENG-9','artifact_path':None}, '/tmp'))"` → `None`
- **SATISFIES**: AC #4

### UPDATE `autopilot/bin/ap-decide.py` — the two `kind` branches

- **IMPLEMENT**:
  1. **The shared draft-review tier** (Phase 1's merged tiers 1 & 2, which after this scans `("plan-review", "piv-draft-review")` seq-ordered): per entry, derive the fork from its state, and for `piv-draft-review` **branch on `ap_queue.ticket_kind(entry)`**:

     | state | kind | approve branch → | claim state | artifact resolver | decision key | feedback branch → | claim state |
     |---|---|---|---|---|---|---|---|
     | `plan-review` | — | `implement` *(legacy, inert)* | `building` | `resolve_plan_path` | `planPath` | `replan` | `planning` |
     | `piv-draft-review` | `bug` | `fix` | `piv-implementing` | `resolve_rca_path` | `artifactPath` | `re-investigate` | `piv-drafting` |
     | `piv-draft-review` | `feature` | `build` | `piv-implementing` | `resolve_piv_plan_path` | `artifactPath` | `redesign` | `piv-drafting` |

     Everything else is unchanged from Phase 1's structure: feedback wins over a stale approval; the feedback branch needs the plan lane free, the approve branch needs the build lane free; `_issue_lock_free` before any claim; unresolved artifact → `needs-input` + `continue`, never `break`; `auto_approve`/`pending_approval`/`--auto-approve` semantics preserved identically; a `trace(...)` on every branch including the skips.
  2. **Tier 5 (intake)**: Phase 1's `ticket_kind` branch, with the feature arm now emitting `{"action": "design"}` and claiming `piv-drafting` instead of `{"action": "plan"}` / `planning`. Keep the `note` → `feedback` pass-through for both. **`plan` is no longer emitted by any tier.**
  3. **Tier 3 (needs-input answers) — corrected by the plan-critic audit: route by every phase name a wrapper can actually write, including a phase's own re-entry name, not just its first-round name.** `ap-cycle.sh` sets `phase_at_question` from the act's own dispatched phase argument, and both this plan's and Phase 1's `--feedback` re-dispatch arms pass the *re-entry* phase string (`redesign`, `re-investigate`) rather than the first-round name (`design`, `investigate`) — so a ticket parked a **second** time, mid-`redesign` or mid-`re-investigate`, carries a `phase_at_question` value the routing must also match, or it falls through to the tier's existing default (`→ replan`, the legacy dispatch). The full corrected table, every value on the left required:

     | `phase_at_question` | action | claim state |
     |---|---|---|
     | `design`, `redesign` | `redesign` | `piv-drafting` |
     | `build` | `redesign` *(re-plan, not re-build — matches Open Question #11's "heavy-handed but consistent" choice)* | `piv-drafting` |
     | `investigate`, `re-investigate` | `re-investigate` | `piv-drafting` |
     | `fix` | `re-investigate` | `piv-drafting` |
     | `plan`, `replan`, or absent | `replan` *(legacy — the ONLY value(s) that still reach it; this is a real value the legacy path itself can produce, not a fallback)* | `planning` |
     | `ship`, `review` | *(skip, trace line)* | — |
     | **any other value** — corrected by red-teaming this plan (see `ADVERSARIAL REVIEW`) | **`needs-input`**, `question: "unrecognized phase_at_question value: '<value>' — routing unknown, needs a human decision"` — **never `replan`** | unchanged (no claim) |

     **This tier reads no `kind`**: every phase name above is either bug-only or feature-only, so the phase already determines the fork. State that in a comment — it is why the kind-read count is two, not three. State the general lesson explicitly too: **every phase name a wrapper can ever write to `phase_at_question` must appear on the left side of this table, or a twice-parked ticket falls through to the fallback** — this is the general form of the bug the fable audit caught here.

     **The fallback for a genuinely unrecognized value must fail closed (`needs-input`), not dispatch the legacy pipeline (`replan`).** The plan-critic audit's fix (the table above) correctly completes the *known*-value routing, but an earlier draft still let an unanticipated *future* value (a renamed phase, a new pipeline someone adds later) fall through to `replan` — silently re-dispatching `/implement-issue`'s planner against a ticket that may be mid-piv-pipeline with an open PR and uncommitted worktree state already. Red-teaming this plan found this is not hypothetical: the live queue's history shows a real near-miss of exactly this shape on ticket ENG-1373 (a parked `implement`-phase question, answered, racing the stale-claim sweep, producing two false "stale, no active run" verdicts against a session that was still genuinely working) — the most fragile joint already in the system, which this plan's wider phase-name surface makes more likely to hit, not less. This costs nothing today: `plan`/`replan`/absent are the only values that can currently reach this tier from a real dispatch, so making *every other* value fail closed changes no currently-reachable behavior, it only closes the door on future drift. Mirror the pattern `ap retry`'s `REQUEUE_STATE.get(phase)` miss already uses elsewhere in this codebase — fail closed and loud, not silent — rather than inventing a new shape.
  4. **`sweep_stale`**: the state tuple is `("planning", "building", "shipping", "piv-drafting", "piv-implementing", "piv-reviewing")`. No feature-specific addition beyond Phase 1's — the three running piv states are shared.
  5. Update the module docstring's tier summary.
- **PATTERN**: Phase 1's tier tasks verbatim in structure; `:245-269` for the resolve-or-`needs-input`-then-`continue` shape; `:282-283` for a lane-busy trace skip.
- **GOTCHA**: Add the comment Phase 1's invariant now requires: **this and the `queued` intake tier are the only two places the decider reads `kind`.** Anyone adding a third should ask whether the phase or the state already encodes what they need.
- **GOTCHA**: Keep the legacy `plan-review` row **exactly** as it is. It is unreachable from intake but still claimable if a human hand-sets the state via `ap sessions [s]`, which is the deliberate manual escape hatch.
- **GOTCHA**: `_issue_lock_free`'s mid-shutdown race applies to `piv-draft-review` for both kinds — the ENG-1327 failure. Do not skip the check.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_decide.sh && ap decide`
- **SATISFIES**: AC #3, AC #4, AC #5

### UPDATE `autopilot/bin/ap-cycle.sh` — the feature dispatch arms

- **IMPLEMENT**:
  1. **Lane arms** in the action case statement: `design|redesign)` joins the existing `plan|replan)` arm (plan lane, no ports); `build)` joins the `implement)` arm's lane/slot/port acquisition (build lane, `5173+n`/`8000+n`) **without** the chained second `run_claude` — the same shape Phase 1 gives `fix)`. In practice this means the arm reads `plan|replan|design|redesign)` and `implement|fix|build)`.
  2. **`act_model`**: `design|redesign) echo "${AP_DESIGN_MODEL:-opus}"`, `build) echo "${AP_BUILD_MODEL:-sonnet}"`. Extend the existing design-vs-execution comment: design is the judgment-heavy half (Phase 4's strategic reasoning, the 5b audit, the 5d gate) and gets opus exactly as planning and investigation do; build executes a settled plan and gets sonnet, matching the `implementer` sub-agents it dispatches.
  3. **`window_name_for`**: no change — `design`/`build` run on the existing `plan`/`build` lanes, whose arms already exist. Verify and comment: the phase group in `ap-runs.py:80-82`'s `_ACT_WINDOW_RE` is `[^_]+`, and none of `design`/`redesign`/`build` contains an underscore, so `act_plan_ENG-1400_design` and `act_build_2_ENG-1400_build` both parse.
  4. **Dispatch arms**:
     - `design)` → `run_claude "design" "/piv-plan-implementation $issue --headless"`
     - `redesign)` → same + `--feedback '$feedback_escaped'`, reusing the existing apostrophe-escaping
     - `build)` → folded into the `fix|build)` arm from the Phase-1 amendment task: `run_claude "build" "/piv-implement --headless --plan $artifact_path --issue $issue --ports fe=$fe_port,be=$be_port"`, then the shared post-`DONE` `queue_set … --state piv-review-pending` + notify.
  5. **Requeue map**: `design|redesign) requeue_state="queued"`, `build) requeue_state="piv-draft-review"`, alongside Phase 1's bug rows and the untouched legacy rows.
  6. **DONE branch**: the plan-ready branch gains `design|redesign` alongside Phase 1's `investigate|re-investigate`, with the wording swapped to `plan ready for review: <issue>` / `plan auto-approved, building: <issue>` and the same `auto_will_build` computation (global `AP_AUTO_APPROVE` or the ticket's own `auto_approve`) so the owner can tell "waiting on you" from "about to build" at a glance. The `ship|review` branch is already right.
  7. **Inert markers**: one comment above the `plan)`, `replan)`, `implement)` and `ship)` dispatch arms and above the `implement)`/`ship)` lane arms: *"DEAD as of docs/plans/2026-09-03-ap-piv-feature-fork-pipeline.md — no decider tier emits this action any more (see ap-decide.py's tier 5 and the shared draft-review tier). Kept deliberately inert, not deleted: a hand-set legacy state via `ap sessions [s]` still reaches it, which is the manual escape hatch while the piv feature fork is unproven. Removal belongs to the legacy-cleanup plan."* Same marker above the implement→ship chain block.
  8. **A `*)` catch-all arm on the lane-lock action `case`, closing a real gap found by red-teaming this plan (see `ADVERSARIAL REVIEW`).** `ap-decide.py` claims a ticket (writes its new state) *before* returning the decision to `ap-cycle.sh`. The lane-lock `case "$action"` statement that acquires a slot/lock for the decided action has no `*)` arm today — an unrecognized action falls through, logs "unknown action", and exits, **leaving the ticket claimed but never dispatched.** This predates this plan, but tier 5 now routes 100% of intake through a `kind`-branched action instead of a hardcoded `"plan"` constant, which is exactly the kind of surface a typo, a partial rollout, or a future drift can hit — and it would strand every subsequent new ticket, not one edge case. Add a `*)` arm that, on an unrecognized action: writes the ticket to `needs-input` with `question: "unrecognized action '<action>' from the decider — routing unknown, needs a human decision"` (never a bare log-and-`exit 0` with the ticket left claimed in limbo), and logs the same text loudly to the cycle's own output. Mirror the fail-closed-and-loud shape `ap retry`'s `REQUEUE_STATE.get(phase)` miss already uses elsewhere in this codebase (`"don't know how to re-queue phase '<x>'"`) rather than inventing a new one.
  9. **The external-failure requeue `case "$final_phase"` needs the same catch-all treatment — see the `UPDATE docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md — generalize the two wrapper arms and add the feature dispatch` task above, which amends Phase 1's `ap-cycle.sh — reconcile` task directly.**
- **PATTERN**: `:804-806` (plan), `:809-812` (replan feedback escaping), `:813-833` (implement + wrapper state swap + ping), and Phase 1's own `fix)` arm.
- **GOTCHA**: **Do not remove the `/implement-issue --phase plan` dispatch line**, despite nothing reaching it. Verified: after this change no tier emits `plan`, `replan`, `implement` or `ship`; the arms are unreachable from `ap-decide.py`. They stay for the escape-hatch reason above, and because deleting them would require editing the pre-existing `test_cycle.sh` cases that assert on the legacy prompt text — which is exactly the check that proves the legacy path was not modified.
- **GOTCHA**: `run_claude` prepends `--run-dir $AP_RUN_DIR`; each prompt is one argument and must not contain `--run-dir` itself.
- **GOTCHA**: `ap-cycle.sh` `cd`s to `$WORK_REPO` before dispatching and skill discovery is cwd-based. `piv-plan-implementation` and `piv-implement` are symlinked into `$AP_WORK_REPO/.claude/skills/` today but are **not** installer-managed; Phase 1's installer task adds `piv-*` names to `SKILL_NAMES`/`EXCLUDE_BODY` — verify `piv-plan-implementation` and `piv-implement` are in that list and add them if Phase 1's list omitted them. Do not `cd` a dispatch into a worktree.
- **GOTCHA — a second, separate list needs the same two names.** `autopilot/tests/test_install_skills.sh` has its **own** hard-coded skill-name list, independent of the installer's `SKILL_NAMES` — it does not read the installer's list automatically. `piv-plan-implementation` and `piv-implement` must be added there too, or Level 3's `test_install_skills.sh` run will not actually verify either skill's symlink/exclude convergence despite passing.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-cycle.sh && shellcheck /home/coder/coder-packages/autopilot/bin/ap-cycle.sh && grep -n 'piv-plan-implementation\|piv-implement --headless\|DEAD as of' /home/coder/coder-packages/autopilot/bin/ap-cycle.sh`
- **SATISFIES**: AC #5, AC #6, AC #13

### UPDATE `autopilot/bin/ap-resume.sh` — feature phases in the resume/park path

- **IMPLEMENT**:
  1. **DONE branch**: widen Phase 1's `fix)` arm to **`fix|build)`** (per the amendment task) writing `piv-review-pending` + the notify ping; widen the plan-ready branch to `plan|replan|investigate|re-investigate|design|redesign`, with per-fork notify wording. **The `fix`-phase-DONE gap Phase 1's audit found applies identically to `build`** — same reasoning, same failure (stranded at `needs-input`, unclaimed by any tier and unswept by `sweep_stale`), same fix, and it must land in the same pass or the feature fork ships with a known permanent-stall bug.
  2. **Lane re-acquisition `case "$lane"`**: no change. `design`/`redesign` resume on the plan lane and `build` on the build lane, both of which already have arms; Phase 1 adds the `review)` arm.
  3. NEEDS_HUMAN (`:472-482`) and FAILED (`:484-494`) are already phase-agnostic — verify by reading and leave a comment recording the confirmation, so nobody adds a redundant branch.
  4. **Inert marker** above the `implement)` chained-ship branch (`:431-468`): same wording as `ap-cycle.sh`'s, plus the note that this is the pipeline's most intricate code and its unreachability is the strongest argument for the cleanup plan.
  5. Extend the header comment (`:25-31`), which records what this script deliberately does **not** replicate (the external-failure requeue classification), to say the gap now covers the piv phases too — rather than silently widening it.
- **PATTERN**: `:319-326` (the ship lane arm's shape), `:424-430` (the DONE phase branches), and Phase 1's own `ap-resume.sh` task.
- **GOTCHA**: Phase 1's standing invariant applies with full force here: **`ap-resume.sh`'s DONE branch is a second, independent reconciliation implementation from `ap-cycle.sh`'s — the two share no code.** Every phase either file learns, the other must learn identically, or a parked-then-resumed act silently strands its ticket. Re-check this whenever either file's phase list changes, not just for this plan.
- **GOTCHA**: Do not generalize `:438`'s `act_build_${acquired_lock_file##*.}_…` window-name string trick. It is reached only from the now-unreachable `implement)` branch and there is nothing to chain.
- **VALIDATE**: `bash -n /home/coder/coder-packages/autopilot/bin/ap-resume.sh && shellcheck /home/coder/coder-packages/autopilot/bin/ap-resume.sh && grep -n 'fix|build' /home/coder/coder-packages/autopilot/bin/ap-resume.sh`
- **SATISFIES**: AC #6

### UPDATE `autopilot/bin/ap-runs.py` — the feature phases in every reader

- **IMPLEMENT**:
  1. **`REQUEUE_STATE`** gains `"design": "queued"`, `"redesign": "queued"`, `"build": "piv-draft-review"` alongside Phase 1's bug rows and the untouched legacy rows. **Must match `ap-cycle.sh`'s requeue map exactly** — same table, two files, per this repo's duplicate-small-helpers convention; extend the cross-reference comment Phase 1 adds to both.
  2. **`_queue_note`**: no new state branches needed — the five piv states are already handled by Phase 1's edits once renamed. **Verify** the wording is kind-agnostic and adjust: `piv-draft-review` should read `awaiting `ap approve`` / `approved -- implementing next cycle` / `auto-approve on`, not "fixing next cycle"; the no-live-session fallback should list `piv-drafting`, `piv-implementing`, `piv-reviewing`.
  3. **`_ACT_WINDOW_RE`**, `QUEUE_DASHBOARD_STATES`, `PENDING_STATES`, `TERMINAL_STATES`: **no change** — Phase 1's edits already cover them once the states are renamed, and no new lane or state is added here. Verify each by reading and record the confirmation in a comment.
  4. **`cmd_queue`'s `--kind`** (added by Phase 1): no change. Verify the success line prints the kind for both values.
  5. The oneshot-mode phase-label heuristic around `:155-167` — Phase 1 accepts a cosmetic gap where a live `/piv-investigate-issue` act is labelled by skill name rather than phase. The same gap applies to `/piv-plan-implementation` and `/piv-implement`. **Accepted, unchanged, for the same reason** (display-only, no state or dispatch impact) — but note that after this plan it affects *every* act rather than the bug minority, which raises its priority for the cleanup plan. Record that shift honestly rather than re-litigating it here.
- **PATTERN**: each edit mirrors the adjacent legacy or Phase-1 line.
- **VALIDATE**: `cd /home/coder/coder-packages/autopilot/bin && python3 -m py_compile ap-runs.py && python3 -c "import importlib.util,sys; s=importlib.util.spec_from_file_location('r','ap-runs.py'); m=importlib.util.module_from_spec(s); sys.modules['r']=m; s.loader.exec_module(m); print(sorted(m.REQUEUE_STATE))"`
- **SATISFIES**: AC #6, AC #14

### UPDATE `autopilot/settings/autopilot.json` — one read-only grant

- **IMPLEMENT**: Add **`WebSearch`** to the allow list. Justified by exactly one call site: `piv-plan-implementation`'s Phase 3 (`:183-206`, "Research latest library versions and best practices... Check for breaking changes and migration guides"). `WebFetch` is already allowed but only fetches a known URL; Phase 3's first step is finding which URL. Read-only, no side effects, no repo or network mutation.
- **IMPLEMENT**: **Verify and record that nothing else is needed.** Checked against the live profile: `mcp__linear-server__get_issue`, `list_comments`, `list_issues`, `save_issue` are already allowed (`piv-plan-implementation`'s input resolution and the Linear claim); `Bash(git -C *)` covers every git verb both skills use; `Bash(node *)` — required by Phase 5c's `relay.mjs`, the step-3b adversarial pass and the escalation-ladder diagnosis — is added by Phase 1's permissions task; `Bash(gh pr create *)` likewise; `mcp__github__create_pull_request` is already allowed. **The feature fork needs no other new grant.** Say so explicitly in a comment so a future reader knows it was checked.
- **PATTERN**: the file's narrow, verb-scoped prefixes, and `README.md:282-289`'s rule to extend **after** seeing a denial rather than pre-approving broadly. This front-runs that for one call whose denial is provable by reading the skill, and nothing more.
- **GOTCHA**: Confirm the deny list is untouched and still covers what it must: `mcp__github__merge_pull_request` denied, `mcp__linear-server__save_comment` **absent from allow** (the structural enforcement of "headless never comments on Linear"), `Bash(git reset --hard *)` and raw `--force` denied, direct `main`/`dev` pushes denied.
- **GOTCHA**: Phase 1's known residual risk stands unchanged and is not this plan's to close: `Bash(gh api *)` is broad enough to technically permit `gh api -X PUT repos/.../pulls/N/merge`. Pre-existing, covers the legacy path too, and merge prevention for that path rests on skill prose. Carry the cross-reference.
- **VALIDATE**: `python3 -c "import json; d=json.load(open('/home/coder/coder-packages/autopilot/settings/autopilot.json')); a=d['permissions']['allow']; assert 'WebSearch' in a; assert 'mcp__linear-server__save_comment' not in a; assert 'mcp__github__merge_pull_request' in d['permissions']['deny']; print('ok', len(a))"`
- **SATISFIES**: AC #12

### UPDATE `autopilot/README.md` — the one pipeline, and what went dead

- **IMPLEMENT**:
  1. Rewrite the opening description (`:3-8`) and the `### The decider` section (`:121-132`): **one pipeline, two kinds.** `queued` → (`design` for a feature / `investigate` for a bug) → `piv-draft-review` → (`build` / `fix`) → `piv-review-pending` → `review` → `ready-to-test`. The five shared states, the two places `kind` is read, the three lanes used (plan, build, review).
  2. New `### Retired: the legacy plan/implement/ship chain` subsection replacing `### Ship-only retry` (`:133-150`) in prominence — do not delete the ship-only-retry text, mark it retired in place. State plainly: no decider tier emits `plan`, `replan`, `implement` or `ship` any more; `planning`/`plan-review`/`building`/`shipping`/`ship-pending` are only reachable by hand via `ap sessions [s]`, which is the deliberate manual escape hatch; **`ship-pending` can no longer be produced by any ticket of either kind, so standalone ship-only retries are entirely unreachable and the whole ship lane is dead** — `AP_SHIP_SLOTS`, `lock.ship.1..N`, ports `5181-5186`/`8011-8016`, `ap down`'s ship refusal, `ap status`'s ship slot line, `ap limits --ship-slots`. All of it stays in the code; the cleanup plan removes it.
  3. Concurrency table (`:201-237`): annotate the ship row **`(dead — see "Retired")`**, keep the review row Phase 1 adds, and keep the ship lane in the lock list at `:339-352` with the same annotation.
  4. Env list (`:32-59`): annotate `AP_SHIP_SLOTS` as retired; add `AP_DESIGN_MODEL` / `AP_BUILD_MODEL` alongside Phase 1's `AP_INVESTIGATE_MODEL`/`AP_FIX_MODEL`/`AP_REVIEW_MODEL`; fix `:49-59`'s omission of `AP_PLAN_SLOTS` if trivial.
  5. **New paragraph on the plan lane's changed load**, the one operational consequence worth documenting: after this cutover **100% of tickets — both kinds — enter through the plan lane** (`ap-decide.py` tier 5), and every one of them runs a long opus design/investigate act with sub-agent fan-out, a `plan-critic` audit and a Codex second draft. `AP_PLAN_SLOTS` defaults to 1, which was already the pipeline's tightest artificial bottleneck (the ENG-1407 case recorded at `ap-env.sh:94-112`). Recommend `ap limits --plan-slots 2` at cutover; do not change the shipped default.
- **PATTERN**: `README.md:201-237`'s table-then-rationale structure.
- **VALIDATE**: `grep -n 'piv-draft-review\|Retired\|plan-slots 2' /home/coder/coder-packages/autopilot/README.md`
- **SATISFIES**: AC #14

### UPDATE `claude/skills/daily-brief/SKILL.md` — kind-aware section wording

- **IMPLEMENT**: Phase 1 adds five sections for the bug states; after the rename they are the shared sections and their wording must serve both kinds:
  - **Awaiting your review** (`state: piv-draft-review`) — the ticket line names what is waiting: `[bug] RCA` or `[feature] plan`, plus the artifact path, the `ap approve` prompt, and whether auto-approve applies.
  - **Drafting** (`piv-drafting`), **Implementing** (`piv-implementing`), **Review pending** (`piv-review-pending`, PR open + review queued), **Reviewing** (`piv-reviewing`, rounds in flight) — one line per ticket, `eng_id` + kind prefix + note.
  - Mark the legacy sections (**Planning**/**Awaiting your approval**/**Shipping**/**Ship pending**) as retired-but-rendered: keep them (a hand-set state still needs to show up) and note in the input contract that they should normally be empty.
  - Input contract (`:21-31`): a queue entry carries `kind`; prefix every ticket line with `[bug]` / `[feature]`.
- **PATTERN**: `daily-brief/SKILL.md:64-102` — one section per state, one line per ticket.
- **GOTCHA**: Doc-only and small, but without it a ticket sitting at `piv-draft-review` is invisible in the 07:00 digest — the main "what needs me today" surface, and after this cutover it is where **every** ticket waits.
- **VALIDATE**: `grep -n 'piv-draft-review\|piv-review-pending\|\[feature\]' /home/coder/coder-packages/claude/skills/daily-brief/SKILL.md`
- **SATISFIES**: AC #14

### UPDATE `autopilot/tests/test_decide.sh` — feature-kind cases only

- **IMPLEMENT**: New cases, scoped to what is **new here** — feature-kind dispatch through the shared states. Phase 1's cases already cover bug-kind through the same tiers and must not be duplicated; they only need their state-name strings updated by the rename task.
  1. `queued` + `kind=feature` → `action: design`, state `piv-drafting`.
  2. `queued` with **no `kind` key at all** → `action: design`, state `piv-drafting`. **The single most important case in this file**: it is the back-compat contract for every ticket on disk, and it is the one assertion that changes meaning versus Phase 1 (where the same input produced `action: plan`).
  3. `piv-draft-review` + `kind=feature` + `pending_approval` + a resolvable plan fixture → `action: build`, `artifactPath` set, state `piv-implementing`.
  4. `piv-draft-review` + `kind=feature` + `feedback` → `action: redesign`, feedback relayed, state `piv-drafting`, `feedback` cleared.
  5. `piv-draft-review` + `kind=feature` + `feedback` + `pending_approval` → feedback **wins** (mirrors the existing precedence case).
  6. `piv-draft-review` + `kind=feature` + approval, plan path unresolvable → `needs-input`, `phase_at_question: "design"`, scan continues.
  7. **Cross-kind fairness at the shared gate**: a `kind=bug` and an older-`seq` `kind=feature` ticket, both at `piv-draft-review`, both approved, build lane free → the **older seq** wins and gets `action: build`. Neither kind starves the other at the one state they share.
  8. `needs-input` + `feedback` + `phase_at_question: "build"` → `action: redesign` (tier 3 routes by phase, no `kind` read).
  9. `needs-input` + `feedback` + `phase_at_question: "design"` → `action: redesign`.
  9b. **Second-round re-entry**: `needs-input` + `feedback` + `phase_at_question: "redesign"` → `action: redesign` (not a fall-through to legacy `replan`); likewise `phase_at_question: "re-investigate"` → `action: re-investigate`. This is the direct regression test for the tier-3 gap the plan-critic audit found: a ticket parked a *second* time carries the re-entry phase name (`redesign`/`re-investigate`), not the first-round name, and without this case the routing table's own left-hand-side gap would go undetected.
  10. **Resolver anchoring**: a ticket `ENG-123` at `piv-draft-review` with `docs/plans/ENG-1234-other.md` present and `docs/plans/ENG-123-mine.md` present → resolves `ENG-123-mine.md`. With only `ENG-1234-other.md` present → `needs-input`, **not** a mis-resolution. This is the regression test for the hazard `resolve_plan_path` still carries.
  11. **Legacy inertness**: a `queued` ticket never produces `action: plan`; a hand-seeded `plan-review` ticket **still** produces `action: implement` with `planPath` (the escape hatch works).
  12. `piv-drafting`/`piv-implementing`/`piv-reviewing` with no ledger row in 3h and no lock held → swept to `failed` (shared sweep, one case, not per-kind).
  13. **Correction required, not preservation**: Phase 1's pre-existing case 2 (`queued` with no `kind` key → `action: plan`/state `planning`) and any other pre-existing `queued`-seeded case asserting `action: plan` **must be rewritten** to assert `action: design`/state `piv-drafting` instead. This is a real behavior change this plan makes — after the intake cutover no state ever maps to `action: plan` again — not new coverage layered on top of unchanged tests. The plan-critic audit caught this: a claim that these cases "pass unmodified" is false, since their expected value literally changed. The cases covering `plan-review`→`implement` and `ship-pending`→`ship` (the still-reachable hand-set escape hatches) genuinely do pass unmodified, and *those* are the correct evidence that the legacy dispatch code itself was not touched.
  14. **`kind` validation, found by red-teaming this plan (see `ADVERSARIAL REVIEW`)**: `queued` + `kind="Bug"` (wrong case) → `action: design` (resolves to `feature`, the safe default), never `action: investigate` — regression test for `ticket_kind()`'s `entry.get("kind") or DEFAULT_KIND` gap, where a present-but-invalid value was truthy and passed through unvalidated instead of being caught and defaulted.
  15. **Fail-closed fallback, found by red-teaming this plan**: `needs-input` + `feedback` + `phase_at_question: "some-future-phase-nothing-defines"` → `needs-input` with a `question` naming the unrecognized value, **never** `action: replan`. Regression test for the tier-3 fallback fix — an unrecognized value must never silently dispatch the legacy pipeline against a ticket that may be mid-piv-pipeline.
- **PATTERN**: `test_decide.sh:105-110` onward; `seed_ticket` already JSON-decodes extra fields so `kind=feature` works as-is. Add a `seed_piv_plan_file` helper mirroring `test_cycle.sh:85-91`'s `seed_plan_file` — it writes `docs/plans/<ENG-ID>-<slug>.md` rather than the legacy `<eng-lower>-thing.md`.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_decide.sh`
- **SATISFIES**: AC #15

### UPDATE `autopilot/tests/test_cycle.sh` — stub + feature cycle cases

- **IMPLEMENT**:
  1. **Stub first**: the `claude` stub's phase detection (`:114-121`) must learn the feature prompts — `*piv-plan-implementation*` → `design`, `*piv-implement --headless*` → `build`. **Order matters against the pre-existing blanket `[[ "$prompt" == *--feedback* ]] && phase="replan"` override at `:121`**, which runs after the case statement and unconditionally wins. Phase 1 already flags that this override must become fork-aware for `re-investigate`; it now needs a third branch: `redesign` when the prompt also matches `*piv-plan-implementation*`, `re-investigate` when `*piv-investigate-issue*`, `replan` otherwise. Get this wrong and every feature-feedback case silently asserts against a legacy phase.
     **Careful with the `piv-implement` matcher**: `*piv-implement*` also matches `piv-implement-issue`. Match on the full token (`*piv-implement --headless*` / `*piv-implement-issue*`) and order the `-issue` case first.
     Add `AP_TEST_DESIGN_STATUS` / `AP_TEST_BUILD_STATUS` knobs plus the matching `AP_TEST_SKIP_STATUS_*` / `AP_TEST_EXIT_CODE_*` variables to `AP_TEST_VARS` (`:291-299`).
  2. **New cases**, feature-kind only:
     - `queued` + `kind=feature` → exactly one claude call, prompt contains `/piv-plan-implementation ENG-x --headless` and `--run-dir`, ticket at `piv-drafting`, cwd is the work repo.
     - Same with `AP_TEST_ACT_STATUS=DONE` → the wrapper's DONE branch pings `plan ready for review`; assert the **notify** text (the stub writes no queue state), matching how the existing plan-DONE cases assert.
     - Same, with the ticket's `auto_approve` set → the ping says `plan auto-approved, building`, not `ap approve`.
     - `piv-draft-review` + `kind=feature` + approved → prompt contains `/piv-implement`, `--plan`, `--issue ENG-x`, and `--ports fe=5174,be=8001` for build slot 1; the same with slot 1 held → `fe=5175,be=8002`.
     - **`build` DONE → exactly one claude call this cycle** (no chained ship!), ticket at `piv-review-pending`, notify says `review pending`. This is the assertion that proves the implement→ship chain is unreachable for a feature ticket.
     - `NEEDS_HUMAN` at each of `design`/`build` → `needs-input` + the right `phase_at_question` + the notify + (persistent mode) a parked-registry entry.
     - `FAILED` with an external signature at each feature phase → requeued to `queued`/`piv-draft-review` respectively, `history` names the matched line, `fail_count` still incremented.
     - `FAILED` with no external signature at a feature phase → terminal `failed` with a real reason in `history`.
     - **Parked-and-resumed `build` act**: persistent mode, a `build` act parks to `needs-input` (NEEDS_HUMAN), then `ap-resume.sh` resumes it to `AP_TEST_ACT_STATUS=DONE` — assert the ticket ends at `piv-review-pending`, not stranded at `needs-input`. The regression test for widening `fix)` to `fix|build)`, and the direct analogue of the case Phase 1's audit added.
     - Persistent mode: a design act's window is named `act_plan_ENG-x_design` and a build act's `act_build_1_ENG-x_build`, and `ap-runs.py`'s `_ACT_WINDOW_RE` matches both.
     - **Legacy inertness**: a full cycle over a `queued` ticket never invokes `/implement-issue` or `/ship-work`. Assert on recorded claude argv.
     - **Unrecognized action does not strand a claim, found by red-teaming this plan (see `ADVERSARIAL REVIEW`)**: seed a ticket at a state that resolves to a decider action the lane-lock `case` doesn't recognize (simulate a future/typo'd action string directly in the decision JSON the stub or a test hook supplies). Assert the ticket ends at `needs-input` with a question naming the unrecognized action — **never** left claimed with no dispatched claude call and no state change. Regression test for the lane-lock catch-all fix.
  3. **Correction required, not preservation**: the pre-existing suite has roughly five or more `queued`-seeded cases that assert the legacy `implement-issue --phase plan` prompt text. These are not "the legacy path, left alone" — after this plan's intake cutover, no `queued` ticket of any kind ever produces that prompt again, so every one of these cases must be **rewritten** to assert `/piv-plan-implementation` instead. The plan-critic audit caught this: it is a required correction to existing assertions whose expected value changed, not new coverage layered on top of an unmodified file. Only the cases exercising `plan-review`→`implement` and `ship-pending`→`ship` (the hand-set escape hatches) are genuinely expected to pass unmodified.
  4. **Not re-tested here**, deliberately: everything Phase 1's cases already cover for bug-kind through the same shared states and the same shared lanes — the review lane's ports and exhaustion, the review dispatch prompt, `AP_REVIEW_SLOTS` clamping, the port-collision matrix. Those assertions are kind-independent; duplicating them per kind would double an already-1653-line file for no new coverage. Say so in a comment where the feature cases begin.
- **PATTERN**: `test_cycle.sh:1103-1185` (build slot cases and port assertions) and `:868-940` (lane-held cases).
- **GOTCHA**: `run_case` defaults `AP_ACT_LAUNCH_MODE=oneshot` deliberately, so most new cases need no tmux. Only the window-name and parked-resume cases set `persistent` plus their own isolated `AP_TMUX_SESSION`.
- **GOTCHA**: `hold_lane_lock` must not be called via `$(...)` — the sandbox reaps the subshell's background job. Copy the existing call convention exactly.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_cycle.sh`
- **SATISFIES**: AC #15

### CREATE `autopilot/tests/test_piv_states.sh` *(optional but recommended)*

- **IMPLEMENT**: One small guard harness for the properties this plan's design rests on, which no other test asserts:
  1. `ap_queue.STATES` contains exactly the expected set — shared + legacy five + piv five, no more.
  2. **No piv state name contains a legacy state name as a substring** (the grep-honesty rule).
  3. **No phase name contains an underscore** — iterate `REQUEUE_STATE`'s keys and assert against `ap-runs.py`'s `_ACT_WINDOW_RE`.
  4. `ap-cycle.sh`'s requeue map and `ap-runs.py`'s `REQUEUE_STATE` agree, extracted from both files and compared.
  5. Every state in `ap_queue.STATES` renders a real note via `_queue_note` (promote Phase 1's Level-5 ad-hoc check into a permanent test).
- **PATTERN**: `test_decide.sh:1-19` (harness header, `pass`/`fail`/`assert`); `test_cycle.sh`'s trailing `ALL PASS` / `N FAILURE(S)` + exit code.
- **GOTCHA**: Property 4 is the one that keeps failing silently in production — two files, one table, by convention. If extracting the bash map is too brittle, assert it by hand with a comment naming both file:line sites, and accept the manual coupling honestly rather than skipping the check.
- **VALIDATE**: `bash /home/coder/coder-packages/autopilot/tests/test_piv_states.sh`
- **SATISFIES**: AC #15

### *(Conditional)* ADD a one-time live state migration — **only if Phase 1 was already executed**

- **IMPLEMENT**: **Skip this task entirely** if the Phase-1 amendment pass landed before Phase 1 was implemented, which is the intended sequencing and the state of the world at drafting time (verified: `ap_queue.STATES` contains none of the bug states, and all 24 live tickets are terminal).

  If Phase 1 *has* already shipped and bug tickets have flowed, the rename becomes a live-data migration. It still does not need code:
  1. `ap pause`.
  2. `python3 ap_queue.py --ap-home ~/.autopilot list` and grep for the five old names.
  3. If **zero** tickets are in them: apply the rename, `ap resume`. Done.
  4. If any are: **drain them** — let in-flight acts finish (`ap sessions` to watch), approve or reply to anything at `rca-review`, wait for `ready-to-test`/`failed`/`done`. The queue is small (24 tickets total, all terminal today) and each act is minutes-to-an-hour, so draining is a same-day operation.
  5. Only if draining is genuinely impractical: a five-line `python3` loop over `$AP_HOME/queue/*.json` rewriting `state` per the mapping table, run under `ap pause`, with `cp -r ~/.autopilot/queue ~/.autopilot/queue.bak.<date>` first. **Do not write this as a committed script** — a one-time migration that lives in the tree is a footgun for the next reader.
- **GOTCHA**: The reverse hazard is the one to actually watch: **do not implement Phase 1's document from a stale copy.** If anyone has a checkout or a working session holding the pre-amendment text, they will wire the bug states into a machine expecting the piv states. Land the amendment pass and the code in the same session, and re-read the amended document before executing any Phase-1 task.
- **VALIDATE**: `python3 -c "import sys; sys.path.insert(0,'/home/coder/coder-packages/autopilot/bin'); import ap_queue, glob, json; bad=[p for p in glob.glob('/home/coder/.autopilot/queue/*.json') if json.load(open(p))['state'] not in ap_queue.STATES]; print('orphaned:', bad); assert not bad"`
- **SATISFIES**: AC #16

---

## TESTING STRATEGY

The orchestrator half is well covered by the existing harnesses (a 1653-line `test_cycle.sh`, a 453-line `test_decide.sh`) which stub `claude`/`tmux`/`ap-notify.sh` on `PATH` and seed queue fixtures directly. The skill half is executable prose with no compiler — validated by one supervised live run, not by unit tests. That asymmetry is inherited from Phase 1 and should be stated rather than papered over.

**One new asymmetry is specific to this plan**: the largest single deliverable — the Phase-1 amendment pass — has **no automated test at all**. Its only validation is the negative grep in that task's VALIDATE line plus a human re-read. Treat the amended document as reviewed code: read it end to end after the pass, specifically checking that every VALIDATE line's `grep` still names tokens that exist.

### Unit Tests

- **`test_decide.sh` (extended)**: 13 feature-kind cases covering the intake branch, the shared-gate kind branch in both directions, tier-3 phase routing, cross-kind FIFO fairness at the one shared gate, the resolver's anchoring, legacy inertness, and the shared sweep. Fixtures are JSON files on disk — no network, no `gh`, no model.
- **`test_piv_states.sh` (new, optional)**: the four invariants the design rests on and no other test asserts.
- **`test_queue.sh`** (created by Phase 1): its `rca_path: null` assertion becomes `artifact_path: null` via the amendment; its `kind` default/validation/back-compat cases are unchanged and are exactly the coverage this cutover needs.
- Existing approach followed exactly: `mktemp -d` per case, `seed_ticket` via `ap_queue.new_ticket` so `seq` is assigned the real way, one `assert` per distinct claim, `ALL PASS`/`N FAILURE(S)` exit contract.

### Integration Tests

- **`test_cycle.sh` (extended)**: the full decide→act→reconcile path for both feature phases with a stubbed `claude`. Asserts on **recorded claude argv** (the prompt is the contract between wrapper and skill; an argv assertion is the only way a prompt-text regression gets caught), the resulting ticket state and `history`, the ledger row's phase/status/model, the notify text, port assignment per slot, the no-chained-ship property, and the parked-then-resumed `build` reconciliation.
- Not covered by any harness, deliberately: real `tmux` injection semantics, and anything requiring a real `claude`, `gh`, or GitHub.

### Edge Cases

- **A ticket file with no `kind` key** → the piv **feature** fork. Highest-value regression test in the plan, and the one whose expected value *changed* from Phase 1.
- A hand-seeded `plan-review` ticket still reaches `/implement-issue --phase implement` — the escape hatch works, and legacy inertness is inertness, not removal.
- A `feature` ticket whose plan cannot be resolved (worktree swept, file renamed) → `needs-input`, not a crash and not a silent stall.
- `ENG-123` resolving against a directory containing `ENG-1234-*.md` → no match, `needs-input`. Never a mis-resolution.
- A bug ticket and a feature ticket both approved at `piv-draft-review` with one build slot → the older `seq` wins, no double-claim (`lock.issue.<id>` enforced), neither kind starves.
- `piv-plan-implementation` reaching Phase 2's gate with nobody there → a plan full of `Assumed —` lines lands at `piv-draft-review`. **Not** a park. The human sees the assumptions at the gate.
- A Linear ticket with an empty body, no comments and no epic → `FAILED` ("nothing to plan from"), not a guess pyramid.
- Twice-`DO NOT IMPLEMENT` from `plan-critic` → `NEEDS_HUMAN`, one of only two park points in the design act.
- A retried `build` act on a branch that already carries the implementation → skips to `piv-create-pr`, which finds the open PR and returns `DONE`-idempotent. **No double implementation, no duplicate PR.**
- A parked `build` act resumed to DONE → `piv-review-pending`, not stranded at `needs-input`.
- `WebSearch` denied → the plan records "external research unavailable" and proceeds; never a stall.
- A crashed feature act (no `status.json`) → `FAILED` per phase, then the 3h stale sweep as the backstop.
- **Rollback with a feature ticket mid-flight**: reverting leaves the ticket in a state no tier claims *and* no sweep sweeps. Recovery is `ap sessions` → `[s]` → set a state by hand. Written into the rollback plan; do not discover it live.

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

### Level 2: Amendment integrity (this plan's own new gate)

```bash
cd /home/coder/coder-packages
# every Phase-1 bug state name is gone except the three enumerated prose exemptions
grep -nE '(^|[^-a-z])(investigating|rca-review|fixing|review-pending|reviewing)([^-a-z]|$)' \
  docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md
# expect exactly: the "Not included: fixing resolve_plan_path" bullet, the resolve_rca_path
# GOTCHA's "fixing the plan-path version", and APPROACH COMPARISON's bug-* record. Nothing else.

grep -n 'rca_path\|rcaPath' docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md   # expect empty
grep -c 'piv-drafting\|piv-draft-review\|piv-implementing\|piv-review-pending\|piv-reviewing' \
  docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md                              # expect > 100
sed -n '/^## AMENDMENTS/,$p' docs/plans/2026-09-03-ap-piv-bug-path-pipeline.md | grep 2026-09-03

# no new state name shadows a legacy one under grep
python3 - <<'PY'
legacy = {"queued","planning","plan-review","needs-input","building","shipping",
          "ship-pending","ready-to-test","failed","done"}
piv = {"piv-drafting","piv-draft-review","piv-implementing","piv-review-pending","piv-reviewing"}
for p in piv:
    for l in legacy:
        assert l not in p, (p, l)
assert not (piv & legacy)
print("state sets disjoint, no substring shadowing")
PY
```

### Level 3: Unit & Integration Tests

```bash
bash /home/coder/coder-packages/autopilot/tests/test_queue.sh
bash /home/coder/coder-packages/autopilot/tests/test_decide.sh
bash /home/coder/coder-packages/autopilot/tests/test_piv_states.sh
bash /home/coder/coder-packages/autopilot/tests/test_cycle.sh
bash /home/coder/coder-packages/autopilot/tests/test_install_skills.sh
bash /home/coder/coder-packages/autopilot/tests/test_runs.sh
bash /home/coder/coder-packages/autopilot/tests/test_brief.sh
bash /home/coder/coder-packages/autopilot/tests/test_sweep.sh
```

All must pass — the last four are regression guards, not new coverage.

### Level 4: Manual Validation

```bash
cd /home/coder/coder-packages && ./scripts/install-autopilot.sh && ./scripts/install-autopilot.sh --check
git -C /home/coder/root-for-local status --porcelain .claude/skills   # expect empty

ap limits                       # review slots present; ship slots present but documented dead
ap status
ap decide                       # dry run against the REAL queue -- never writes

# hand-seeded dry run, PAUSED
ap pause
ap limits --plan-slots 2        # the documented cutover step
ap queue ENG-<a-real-small-feature> "smoke test of the feature fork"   # no --kind: exercises the default
ap decide                       # expect action:design + a trace line naming the kind branch
ap resume

# supervised live end-to-end, one feature, watching each hop:
ap tail latest                  # design act
ap sessions                     # expect piv-draft-review, "awaiting `ap approve`"
cat <the plan path from the ticket's artifact_path>   # expect Assumed- lines and an ADVERSARIAL REVIEW section
ap approve ENG-<id>             # expect the next cycle to dispatch the build act
ap sessions                     # expect piv-review-pending after the build act's DONE
ap runs -n 10                   # expect three ledger rows: design, build, review
gh pr view <n> --json state,reviews   # expect an open, reviewed, UNMERGED PR
```

Success criterion: **three acts, one open PR, review threads worked, ticket at `ready-to-test`, nothing merged, and no `/implement-issue` or `/ship-work` invocation anywhere in the ledger.**

### Level 5: Additional Validation (Optional)

```bash
# the resolver's anchoring, against real fixtures
python3 - <<'PY'
import importlib.util, sys, os, tempfile
s = importlib.util.spec_from_file_location("d", "/home/coder/coder-packages/autopilot/bin/ap-decide.py")
m = importlib.util.module_from_spec(s); sys.modules["d"] = m; s.loader.exec_module(m)
d = tempfile.mkdtemp(); os.makedirs(os.path.join(d, "docs", "plans"))
for n in ("ENG-1234-other.md", "ENG-123-mine.md", "2026-08-01-eng-123-legacy.md"):
    open(os.path.join(d, "docs", "plans", n), "w").close()
got = m.resolve_piv_plan_path({"eng_id": "ENG-123", "artifact_path": None}, d)
assert got and got.endswith("ENG-123-mine.md"), got
assert m.resolve_piv_plan_path({"eng_id": "ENG-99", "artifact_path": None}, d) is None
print("resolver anchors correctly; no substring hazard, no legacy cross-match")
PY

# no decider tier can emit a legacy action any more, except the two genuinely-reachable legacy rows
grep -n '"action": "plan"\|"action": "implement"\|"action": "ship"\|"action": "replan"' \
  /home/coder/coder-packages/autopilot/bin/ap-decide.py
# expect: the legacy plan-review row's "implement" (the hand-set escape hatch), tier 4's
# ship-pending row's "ship", and tier 3's "replan" for its own genuinely-reachable
# plan/replan/absent values ONLY. Tier 3's fallback for any OTHER (unrecognized) value must be
# "needs-input", never "replan" -- if this grep shows "replan" reachable from anywhere but that
# named branch, the fail-closed fix regressed.
```

---

## ACCEPTANCE CRITERIA

- [ ] **AC #1** — Phase 1's document is amended in place: five states renamed at every state-usage site with the three prose exemptions preserved verbatim; the `## Pipelines and their phase vocabularies` table has three rows; the disjointness and kind-read-count invariants are restated correctly; and `## AMENDMENTS` carries a dated entry naming this plan as the reason.
- [ ] **AC #2** — The ticket field is `artifact_path` and the decision key is `artifactPath` for both kinds; the legacy `plan_path`/`planPath` are untouched; no `rca_path`/`rcaPath` remains anywhere.
- [ ] **AC #3** — The decider reads `kind` in **exactly two** places (`queued` intake, `piv-draft-review`), verifiable by grep; tier 3 routes by `phase_at_question` alone and reads no `kind`.
- [ ] **AC #4** — `resolve_piv_plan_path` resolves `docs/plans/<ENG-ID>-<slug>.md` in a worktree then the root, anchored so `ENG-123` never matches `ENG-1234-*.md` and never matches a date-prefixed legacy plan; unresolvable → `needs-input`, never a crash and never a wrong file.
- [ ] **AC #5** — `queued`+`kind=feature` (and `queued` with no `kind` key) → `design`; `piv-draft-review`+`kind=feature`+approval → `build`; +feedback → `redesign`; `piv-draft-review`+`kind=bug` still → `fix`/`re-investigate`; every claim preceded by `_issue_lock_free`; every branch emits a trace line.
- [ ] **AC #6** — The wrapper dispatches `/piv-plan-implementation` and `/piv-implement` with the right flags and ports, writes `piv-implementing → piv-review-pending` itself after a `build` DONE, requeues an externally-failed feature act to `queued`/`piv-draft-review` per phase, and parks with the right `phase_at_question`; `ap-resume.sh` reconciles `design`/`redesign`/`build` identically to `ap-cycle.sh`, including the `build` DONE arm; both requeue maps agree.
- [ ] **AC #7** — Both new skills have a `## Headless mode` section that (a) opens with the pointer sentence, (b) states its phase and `phase_at_question`, (c) carries a skill-specific ask-point→fallback table, and (d) **duplicates none** of the protocol's mechanics.
- [ ] **AC #8** — Artifacts land in tracked, committed, deterministically-resolvable paths: the plan at `docs/plans/<ENG-ID>-<slug>.md`, the report at `docs/plans/reports/<ENG-ID>-<slug>-report.md`, both committed by `/piv-commit` inside their act, and both found by `piv-create-pr`'s and `piv-review-pr`'s kind-branched report lookups. **Nothing is written to `.claude/plans/` or `.claude/reports/` headlessly.**
- [ ] **AC #9** — `piv-plan-implementation` has a Phase-5d conditional red-team gate with the enumerated guard trigger, a fresh sub-agent that never sees the plan's argument, the five-item require-back list, and a mandatory recorded non-firing trigger; the plan template has an `ADVERSARIAL REVIEW` section; the file states explicitly that `/challenge` does not apply to a forward-looking plan and why.
- [ ] **AC #10** — The clarifying-gate question is answered in the skill: the existing `If they decline` fallback is used verbatim, unanswered items become `Assumed —` lines that form the review agenda at `piv-draft-review`, this is **not** a `NEEDS_HUMAN`, and the exactly-two real park points (twice-`DO NOT IMPLEMENT`, red-team `do not ship as specified`) are named — along with the condition the whole mapping rests on, that the approval gate exists.
- [ ] **AC #11** — `piv-implement` requires an explicit `--plan` (missing → `FAILED`, no queue write) and `--issue`; is idempotent on re-entry; bounds the validation loop at two cycles; ports the scope and secrets gates from `implement-issue`; rebases onto a fresh base before opening the PR; and never changes the ticket's state itself.
- [ ] **AC #12** — The permission profile gains exactly one grant (`WebSearch`), everything else the feature fork needs is verified already present or added by Phase 1, and the deny list is unchanged and still blocks merging and Linear comments.
- [ ] **AC #13** — The legacy path is inert but intact: no tier emits a legacy action for any `phase_at_question` value this plan or Phase 1 defines — `replan` fires only for `plan`/`replan`/absent, its own genuinely-reachable values, never as a fallback for an unrecognized value (tier 3's fallback for any unanticipated `phase_at_question` is `needs-input`, not a legacy dispatch — found by red-teaming this plan, see `ADVERSARIAL REVIEW`); the lane-lock dispatch case and the external-failure requeue case both fail closed to `needs-input` on an unrecognized action/phase rather than stranding a claimed ticket or silently skipping a write; every dead arm carries an inert-marker comment naming this plan and the cleanup plan; **no legacy state, tier, lane, lock, port range or dispatch prompt was modified** — the underlying dispatch code is untouched, verifiable by reading it, even though the pre-existing `test_decide.sh`/`test_cycle.sh` cases that seeded `queued` and asserted the old `action: plan` intake behavior are themselves updated to assert the new `design` intake (this is a required test correction, not evidence the legacy code was touched — see AC #15); the cases covering `plan-review`/`ship-pending` (the still-reachable hand-set escape hatches) pass unmodified; and a hand-set `plan-review` still reaches the legacy dispatch.
- [ ] **AC #14** — `ap status`, `ap sessions`, `ap runs` and the daily brief show a feature ticket at every one of its states with the right kind prefix; the README documents the one pipeline, the two kinds, the retired legacy chain and the **dead ship lane** (including that `ship-pending` is now unproducible and standalone ship-only retries are unreachable), and the `--plan-slots 2` cutover recommendation.
- [ ] **AC #15** — New/extended tests all pass; the pre-existing cases covering `plan-review`/`ship-pending` pass unmodified; every pre-existing `queued`-seeded case that asserted the old `action: plan`/`implement-issue --phase plan` intake behavior is rewritten (not left in place) to assert the new `design`/`piv-plan-implementation` behavior — see the correction to `test_decide.sh`'s item 11 and `test_cycle.sh`'s new bullet on this; the other harnesses still pass.
- [ ] **AC #16** — No live ticket is stranded by the rename: verified either by the amendment landing before Phase 1 is executed (the intended path), or by the drain procedure showing zero tickets in a renamed state.
- [ ] Code follows project conventions and patterns (tier shape, trace lines, pointer-sentence openers, ask-table shape, `caseN:` test descriptions, duplicate-small-helpers).
- [ ] No regressions in existing functionality.
- [ ] Documentation is updated (`autopilot/README.md`, `daily-brief`, Phase 1's document, both new skill files).

---

## COMPLETION CHECKLIST

- [ ] All tasks completed in order
- [ ] Each task validation passed immediately
- [ ] All validation commands executed successfully
- [ ] Phase 1's document re-read end to end after the amendment pass, with every VALIDATE line's grep tokens confirmed to still exist
- [ ] Full test suite passes (`test_queue`, `test_decide`, `test_piv_states`, `test_cycle`, `test_install_skills`, `test_runs`, `test_brief`, `test_sweep`)
- [ ] No linting or type checking errors (`shellcheck` clean, `py_compile` clean, JSON parses)
- [ ] Manual testing confirms the feature works — one supervised live feature end-to-end, three ledger rows, one open unmerged PR, ticket at `ready-to-test`, zero legacy skill invocations in the ledger
- [ ] Acceptance criteria all met
- [ ] Code reviewed for quality and maintainability
- [ ] `ap limits --plan-slots 2` applied at cutover, and the reason recorded in the README
- [ ] Rollback path rehearsed: the state-stranding note in Edge Cases is written where a future operator will find it

---

## OPEN QUESTIONS / ASSUMPTIONS

1. **Settled by an explicit user gate, recorded here so the reasoning survives — immediate full cutover, no pilot flag.** Every `kind: feature` ticket routes to piv from the moment this ships. The argument is in the Solution Statement: the permission-sensitive, PR-mutating half of the chain will already be proven live by the bug fork, leaving only two local-file skills genuinely new to headless. If the first week goes badly, the rollback is `git revert` plus draining, not a flag flip — **which is the cost of this decision and it should be understood before merging**, not discovered.

2. **Settled by the same gate — generalize Phase 1's states rather than adding a third set.** The alternative (a third parallel five-state set) was rejected because it triples the readers of a state machine that already has four independent ones. The cost paid is that `kind` is now read in two decider places instead of one, and Phase 1's cleanest property ("`kind` is read in exactly one place") is weakened. Recorded as a deliberate trade: **more coupling, far less surface.**

3. **Assumed, and the most consequential thing to confirm — browser QA, the four-server baseline comparison, the durable QA artifact (`docs/plans/qa/<eng-id>-qa.md`), `roborev`, and the spec-vs-test audit are dropped for feature tickets.** These are `implement-issue` Phase B capabilities with no equivalent in `piv-implement`. This is **not** the same call Phase 1 made for bugs — Phase 1's reasoning ("a fix's evidence is its reproduction case plus its regression test") explicitly does not transfer to features, and `implement-issue`'s Phase B mandates the comparison *for features* precisely because a feature changes what a user sees.

   The argument for accepting it: browser QA relocates rather than disappears — `/test-issue` is the designed human QA session, it already assembles the PRs, stands up the changed-vs-baseline comparison and runs the e2e spec, and it happens at `ready-to-test`, which is where the merge decision is made anyway. Two of Phase B's gates are *not* accepted as losses and are ported into `piv-implement` explicitly (scope, secrets), and `ship-work`'s rebase-onto-fresh-base property is recovered with two commands.

   **If this is wrong, it is the thing to fix first**: the remedy is a Phase-B-equivalent QA step in `piv-implement`'s headless section, which is a substantial new surface (four servers, port pairs, Playwright, a durable artifact convention) and would directly contradict the "smaller unproven surface" argument for the immediate cutover. Confirm before execution.

4. **Assumed — the state names.** `piv-drafting`/`piv-draft-review`/`piv-implementing`/`piv-review-pending`/`piv-reviewing`. `piv-designing`/`piv-design-review` was the suggested default and was rejected because "design review" is wrong for a bug's RCA, which defeats the point of generalizing. `piv-building` was rejected because it contains the legacy state `building` as a substring and would break grep-based audits. If a different set is preferred, the swap is mechanical **provided it is done before Phase 1 is executed** — and the substring rule must hold for whatever replaces it.

5. **Assumed — the phase names `design`/`redesign`/`build`.** `plan`/`replan`/`implement` were unavailable (they are the legacy actions, kept inert), and `build` as a phase name coincides with `build` as a lane name — `act_build_2_ENG-1400_build` parses correctly but reads oddly. `execute` or `piv-build` were the alternatives. Low stakes, mechanical to change, flagged because it is the kind of thing that annoys daily.

6. **Assumed — the plan path convention `docs/plans/<ENG-ID>-<slug>.md`, deliberately dropping the directory's existing date prefix.** Bought: anchored ENG-id resolution with no substring hazard, and filename-shape distinguishability from legacy plans during coexistence. Paid: two naming conventions in one tracked directory. The alternative — `docs/plans/YYYY-MM-DD-<ENG-ID>-<slug>.md` with a hyphen-anchored `*-<ENG-ID>-*` glob — also avoids the substring hazard and preserves the convention; it is a one-line resolver change if the mixed directory turns out to grate.

7. **Assumed — three acts, not five.** `piv-commit` and `piv-create-pr` ride inside the `build` act, inheriting Phase 1's call and its safety argument (the idempotent re-entry rule). If a retried build ever double-implements, this is the alternative to reach for.

8. **Confirmed by reading, not assumed — the feature fork needs no new permission beyond `WebSearch`.** Linear read/claim tools, `Bash(git -C *)`, `Bash(node *)` (via Phase 1), `Bash(gh pr create *)` (via Phase 1) and `mcp__github__create_pull_request` are all already granted. Re-verify with the Level-1 JSON check before relying on it.

9. **Confirmed by running, not assumed — the migration hazard is currently nil.** The live queue holds 24 tickets, **every one terminal** (`done`/`ready-to-test`/`failed`, verified 2026-09-03), and Phase 1 is unimplemented, so no ticket can be in a renamed state. `ap pause` + drain is sufficient and needs no code. The conditional migration task exists only for the case where Phase 1 ships first. **The real risk is the mirror image**: implementing Phase 1 from a stale, unamended copy of its document.

10. **Open — should `ap retry` on a FAILED `build` act go back to `piv-draft-review` (re-approve, then re-build) or straight to `piv-implementing`?** This plan chose `piv-draft-review`, mirroring both the legacy `implement` → `plan-review` requeue and Phase 1's `fix` → `rca-review` choice. It costs one `ap approve`. Consistency won; say so if you disagree. Phase 1's Open Question #9 is the same question and should be answered the same way for both kinds.

11. **Open — tier 3 routing an answered `build`-phase question to `redesign`** re-runs the *whole* design act because the human answered one implementation question. Heavy-handed, deliberately consistent with both the legacy `implement`→`replan` routing and Phase 1's `fix`→`re-investigate`. It rarely fires (persistent mode injects the reply into the live parked window, and tier 3 excludes parked tickets). Same question as Phase 1's Open Question #10; answer both together.

12. **Assumed — `AP_PLAN_SLOTS` should be raised to 2 at cutover, by `ap limits`, not by changing the shipped default.** After this plan **100% of tickets** enter through the plan lane and every one runs a long opus act with sub-agent fan-out plus a `plan-critic` audit plus a Codex second draft. Phase 1 already flagged this bottleneck (the ENG-1407 case); this plan makes it universal rather than fork-specific. Watch the first week; 3 may be right.

13. **Assumed — the cost profile is acceptable, and it goes up.** A feature now costs opus `design` (with a `fable` audit sub-agent and a Codex `plan-debate` dispatch at `effort: max`) + sonnet `build` (with `implementer`/`codex-feature` sub-agents and a Codex adversarial test pass) + sonnet `review` (with `debate-review`'s two-to-three delegated sessions and `babysit-pr`'s repair rounds). `AP_MAX_ISSUES_PER_DAY=3` counts distinct issues so the cap is unchanged, but `AP_MAX_DAY_COST_USD=50` may bind sooner, and persistent-mode cost figures are **estimates, not billed amounts**. Watch `ap status`'s week line for the first few features before queueing them in volume.

14. **Assumed — a design act's wall-clock runtime is acceptable and nothing kills it.** Verified: `ap-cycle.sh` has **no act timeout of any kind**. The exposure is the harness's own session ceiling, which the protocol's never-background rule addresses, plus the plan lane being held for the duration. Phase 5c at `effort: max` is the single longest blocking step; if design acts routinely run past an hour, the first lever is `--plan-slots`, the second is making 5c conditional on complexity (it is already skipped for Low).

15. **Flagged, not closed — `piv-review-pr` is now the only automated gate between an implementation and the human for *every* ticket.** Under the legacy chain, `ship-work` also confirmed the branch was rebased and locally gate-clean. This plan recovers the rebase inside `piv-implement` (task step 8), but nothing re-checks staleness between PR-open and merge. `babysit-pr` treats CI failures as blockers and GitHub shows conflict state at merge time, so the gap is visible rather than silent — but it is a gap, and it is new for features.

---

## NOTES (open canvas)

### What this plan actually does, in one paragraph

It deletes a pipeline without deleting any code. After it lands, `ap-decide.py` never emits `plan`, `replan`, `implement` or `ship`; every automatic transition goes through five shared states and two skill families; and roughly 400 lines of `ap-cycle.sh`, `ap-resume.sh` and `ap-decide.py` — plus an entire concurrency lane with its own env var, six locks and twelve ports — become unreachable while remaining byte-identical. That is the deliberate shape: **retirement by unreachability, deletion by a later plan.** It gives the cutover a rollback that is a `git revert` rather than a restoration, and it gives a nervous operator a hand-set escape hatch (`ap sessions` → `[s]` → `plan-review`) that still runs the old chain end to end for exactly one ticket.

### The four things most likely to go wrong, in order

1. **A missed occurrence in the Phase-1 amendment pass.** It fails at implementation time, not test time, and the failure looks like "why does `ap_queue.STATES` have both `fixing` and `piv-implementing`". Mitigation: the self-correcting Level-2 process (rename globally, then classify every remaining grep hit by hand — the plan-critic audit found the original enumerated edit-site list undercounted by roughly 45 lines, which is exactly why the process is now classify-and-verify rather than a fixed checklist), and reading the amended document end to end. The specific trap is a `VALIDATE` line whose `grep` alternation still names a renamed token and therefore passes against nothing.
2. **A tier-3 routing gap for a phase's own re-entry name.** Caught by the plan-critic audit: `ap-cycle.sh` writes `phase_at_question` from the act's actual dispatched phase string, and a `--feedback` re-dispatch passes the *re-entry* name (`redesign`, `re-investigate`), not the first-round name (`design`, `investigate`). A tier-3 routing table that only lists first-round names silently falls through to the legacy `replan` default for any ticket parked a *second* time. The general lesson — every phase name a wrapper can ever write must appear on the routing table's left side — is stated explicitly in the `ap-decide.py` task and has its own regression test (`test_decide.sh`'s new case 9b).
3. **The `test_cycle.sh` stub's `--feedback` override.** It is a blanket rule that runs after the phase-detection case statement and unconditionally wins. Phase 1 already caught that it must become fork-aware for `re-investigate`; this plan needs a third branch, and the `*piv-implement*` matcher additionally shadows `piv-implement-issue`. Two ordering bugs in six lines, in a file where a wrong assertion silently passes.
4. **`ap-resume.sh` diverging from `ap-cycle.sh` again.** It has already stranded a ticket once in this migration (Phase 1's audit finding #2, the missing `fix)` arm). This plan widens that same arm to `fix|build)`. If the widening lands in one file and not the other, a parked-then-resumed build act strands at `needs-input` — unclaimed by any tier, unswept by `sweep_stale`, with no diagnostic. There is a regression test for it; run it.

### Why the clarifying gate needed almost no design

Worth stating separately because it is the one place this plan does *less* work than expected. The obvious framing — "an interactive gate in a headless pipeline is a problem to solve" — is wrong here. `piv-plan-implementation` already documents what to do when nobody answers (`:176-178`: honour the decline, name every guess as an `Assumed —` line, never guess silently), and it does so as a *first-class* branch rather than an afterthought. Headless mode is a permanent decline. So the entire headless treatment of the gate is: use the branch that already exists, and confirm the queue semantics around it.

What makes it *correct* rather than merely convenient is the second hop: the plan carrying those `Assumed —` lines goes to `piv-draft-review`, where a human reads it and can `ap reply` before any code exists. **The approval gate is the clarifying interview, made asynchronous.** That is a genuinely better ergonomic than the interactive form — the questions arrive with a full plan as context instead of standing between the analysis and the plan — and it costs nothing.

The dependency is worth naming because it is invisible: this only holds while `piv-draft-review` is a real gate. Auto-approve (`ap queue --auto`, or `AP_AUTO_APPROVE=1`) skips it, and a plan full of unexamined assumptions then goes straight to a build act. That is the operator's call to make, but it should be made knowingly, and the skill's headless section says so.

### Rejected: giving the feature fork its own state set

Considered and rejected in favour of amending Phase 1. Three states per fork per position × three positions is the shape that makes a state machine unreadable, and the concrete cost is countable: `ap_queue.STATES`, `ap-decide.py`'s tiers, `ap-decide.py`'s sweep, `ap-runs.py`'s `QUEUE_DASHBOARD_STATES` / `PENDING_STATES` / `_queue_note` / `REQUEUE_STATE`, `daily-brief`'s enumerated sections — seven readers × five more states. Phase 1's High complexity rating came from adding five states to four readers *once*. The counter-argument (it would avoid amending a live document, which is this plan's biggest single risk) is real but it trades a one-time editing risk for a permanent structural one.

Recorded here because if the amendment pass turns out to be a nightmare in practice, this is the fallback — and it is strictly worse.

### Rejected: an `--engine legacy|piv` flag

A third dispatch path, a third set of test cases, a field on the ticket, and a flag whose removal is its own follow-up plan — to hedge a risk that is mostly already retired by the time this lands. The honest version of the hedge is what this plan actually does: leave the legacy path inert and reachable by hand. That is a flag with a zero-line implementation.

### The traps that would each have cost a full unattended run

Same shape as Phase 1's list — interactive prose that reads fine and fails only at runtime, at 3am, with nobody there:

- **`.claude/plans/` and `.claude/reports/` are both untracked in the work repo** (verified: `?? .claude/plans/`, `?? .claude/reports/`). Both skills default their primary artifact there. Either one creates the exact dirty-tree condition `piv-create-pr`'s "Uncommitted changes → STOP" precondition fires on, at the last step of the act. Hence `docs/plans/` and `docs/plans/reports/`, committed. **This needed checking rather than copying Phase 1's answer** — and the check confirmed the same trap, twice.
- **`feature/<plan-slug>`** (`piv-implement:44`) does not match `Bash(git push -u origin haroun/*)`. Denied, silently, at the last step of the build act. Exactly the `fix/issue-<id>-<slug>` trap Phase 1 catalogued, in a different file.
- **`STOP: commit or stash first`** (`piv-implement:46`) is a bare stop with no stated default — the single most dangerous shape in a headless skill, because a model with no documented fallback will invent one, and the inventable options here are "commit someone's uncommitted work" or "stash it".
- **Step 4's `Continue only when it passes`** (`:176-179`) is an unbounded loop. Headlessly that is an act that holds a build slot until the harness kills it, with no `status.json`.
- **`$ARGUMENTS` is the whole flag string**, not the plan path, under a slash invocation. `piv-implement`'s `Read plan file: $ARGUMENTS` would try to read `--headless --plan docs/... --issue ENG-1400` as a filename.
- **The `test_cycle.sh` stub's `*piv-implement*` glob matches `piv-implement-issue`** — a test-only trap, but one that makes bug-fork cases silently assert against the feature phase.
- **`resolve_plan_path`'s substring glob** would happily resolve `ENG-123`'s plan to `eng-1234-foo.md`. The new resolver anchors; the old one is left alone and left dangerous, on a dead path.
- **`ap-resume.sh`'s DONE branch is a second reconciler.** Already stranded a ticket once in this migration. Widening `fix)` to `fix|build)` in one file and not the other reproduces the same bug for features.

Every one is written into a task's GOTCHA. Collected here because the pattern — *the interactive form is not the headless form, and the difference is invisible until 3am* — is the single most useful thing this migration has produced, and it held for a second fork with a completely different skill pair.

### Rollout sequencing

Order matters in exactly three places:

1. **The Phase-1 amendment pass runs before Phase 1 is executed.** Non-negotiable; it is what turns a live-data migration into a text edit. If that ordering is impossible, run the drain procedure first.
2. **Phase 1 is fully executed before this plan's orchestrator tasks.** This plan's code depends on Phase 1's `kind` field, `ticket_kind()`, multi-state `list_queue`, merged tiers, review lane, `headless-protocol.md`, and the permission grants. There is no partial-order shortcut.
3. **`ap pause` across the two skill-file edits and the Phase-1 document edit** if a live act might read them mid-turn. Everything else is additive to code running acts do not re-read.

Beyond that: the two skill sections (Phase 2) and the orchestrator work (Phase 1) can land in either order or in parallel — the plumbing dispatches prompts nothing will send until a feature ticket is queued, and the skills are inert until dispatched. Then permissions/docs, then tests. The first live feature should be queued with `ap pause` held, `ap decide` inspected for the kind-branch trace line, and only then resumed. Apply `ap limits --plan-slots 2` at the same time.

### Rollback

`git revert` restores the legacy pipeline, since nothing was deleted. Three non-obvious hazards, in order of likelihood:

1. **A feature ticket in flight** lands in a state no tier claims and no sweep sweeps — the piv states and the sweep tuple revert together. It sits silently forever. Check for in-flight tickets (`python3 ap_queue.py --ap-home ~/.autopilot list`, grep the five piv states) **before** reverting, and drain them first.
2. **Phase 1's document reverts with it**, taking the generalized names back to the bug-specific ones. If Phase 1's *code* stays deployed, the document and the machine disagree. Revert both or neither.
3. **A committed plan at `docs/plans/<ENG-ID>-<slug>.md`** is not resolvable by the reverted `resolve_plan_path` (uppercase `ENG-` does not match its lowercase glob). A reverted ticket at `plan-review` will go to `needs-input` rather than mis-resolving — which is the safe failure, and is a small dividend of the naming choice.

---

## PLAN AUDIT — independent model, before this plan is considered done

**Verdict: SOUND WITH FIXES.** An independent `fable`-model pass re-derived this plan's claims against the real repository (both orchestrator files and Phase 1's actual current document text, not this plan's description of it) rather than trusting its own reasoning. The overall design — a shared, kind-agnostic piv state set amending Phase 1's document in place, two `kind`-read locations, an anchored `resolve_piv_plan_path` resolver, and the `fix|build)` reconciler widening — was confirmed consistent with both the code and Phase 1's current text. Four real defects were found and are now fixed in the task text above:

1. **"Every pre-existing legacy case still passes unmodified" was false.** After the intake cutover, `queued` never produces `action: plan` again, so every pre-existing `test_decide.sh`/`test_cycle.sh` case that seeded `queued` and asserted the old `plan`/`implement-issue --phase plan` behavior has an expected value that changed and must be **rewritten**, not preserved. Only the cases exercising the `plan-review`/`ship-pending` hand-set escape hatches genuinely pass unmodified, and those — not the `queued` cases — are the correct proof the legacy dispatch code itself was untouched. Fixed in `test_decide.sh`'s item 13, `test_cycle.sh`'s new item 3, AC #13, AC #15, the top-level Solution Statement bullet, and the NOTES "four things most likely to go wrong" list.
2. **The `rca_path`→`artifact_path` rename's VALIDATE contradicted the same task's own instruction to keep the function `resolve_rca_path`.** `rca_path` is a literal substring of that name, so a bare negative grep could never pass. Fixed with an exclusion (`grep -v resolve_rca_path`) and two missed edit sites (the resolver's own VALIDATE fixture, and a Testing Strategy phrase) added.
3. **The 23-item "exact edit sites" enumeration undercounted by roughly 45 lines**, and the claimed "exactly three prose exemptions" was wrong — one of the three (Codex's rejected `bug-*` vocabulary) never actually matches the stated grep pattern in the first place (a preceding hyphen fails the pattern's own word-boundary class), while a real state reference in a notify string (`RCA auto-approved, fixing:`) needed renaming and wasn't listed. Fixed by replacing the brittle enumeration with a self-correcting process: rename globally, then classify every remaining grep hit as a real miss or one of exactly two known ordinary-English exemptions.
4. **A genuine routing gap in tier 3**: a ticket parked a *second* time (mid-`redesign` or mid-`re-investigate`) carries the phase's *re-entry* name in `phase_at_question`, not its first-round name — and neither this plan's original tier-3 table nor Phase 1's listed that re-entry name on the routing table's left side, so a twice-parked ticket would silently fall through to the legacy `replan` default. Fixed with a corrected, complete routing table, an explicit statement of the general rule ("every phase name a wrapper can ever write must appear on the left side"), and a new regression test case (`test_decide.sh`'s 9b).

Smaller fixes also applied: "zero new env vars" corrected to name the two model-pin overrides this plan actually adds; a documented-file-count correction (~60, not ~40); a missing kata-override instruction for the clarifying gate (the interactive skill's `work.attention needs-human` call must not fire headlessly, since the gate is never a park); an explicit note that `test_install_skills.sh` has its own separate hard-coded skill list needing the same two additions; and a GOTCHA that the daily-brief rename's capitalized section titles won't be caught by the lowercase Level-2 grep.

**What could not be checked**: live permission-matcher semantics for `Bash(git -C *)` (pattern shape confirmed by reading, not by a live denial test); whether the cited files' uncommitted working-tree state will still match by implementation time; `implement-issue/SKILL.md:1160-1231` was not read end-to-end, only its boundaries confirmed.

## APPROACH COMPARISON — Codex's independent second draft (Medium/High complexity)

**Phase 5c: attempted, no usable output.** Codex's sandbox hit the same `bwrap: No permissions to create a new namespace` failure that blocked Phase 1's own Phase 5c attempt — a recurring, previously-observed issue with this Codex CLI installation in this environment, not specific to this plan. Unlike Phase 1's attempt (which caveated around the failure and produced a proposal grounded in public upstream repos instead), Codex this time correctly declined rather than substituting weaker grounding, stating verbatim that it could not read any local files, and that a web fallback found only the public upstream PIV skills repository — not this checkout's custom autopilot code or the unshipped bug-path plan — which would violate the grounding requirement, so it produced no proposal at all.

No corroboration or grafted ideas came from this pass. The design decisions in this plan rest on Phase 4's opus draft and Phase 5b's audit alone. Retry Phase 5c manually if the sandbox is fixed before implementation.

## ADVERSARIAL REVIEW — red-team, guard-touching plans only

**Trigger**: fired. This plan changes `ap-decide.py`'s dispatcher/entry-gate tiers (tier 5's intake action, the shared draft-review tier, tier 3's answered-question routing).

**Verdict: initially `do not ship as specified`.** Reworked once per this rubric's own routing for that verdict; now **ship with the named additions**, all incorporated into the task list above (Fixes A-E).

**The single most severe gap — a claim-before-dispatch race that would strand 100% of new intake, not an edge case.** `ap-decide.py` writes a ticket's new state *before* returning its decision to `ap-cycle.sh`. The lane-lock `case "$action"` statement that acquires a slot/lock for the decided action had no catch-all arm — an unrecognized action fell through, logged "unknown action," and exited, **leaving the ticket claimed but never dispatched**, with no diagnostic and no recovery path (the new state isn't in `sweep_stale`'s tuple either). This predates this plan, but tier 5 now routes every queued ticket through a `kind`-branched action instead of a hardcoded constant — exactly the surface a typo, a partial rollout, or future drift hits, and since tier 5 is the *only* intake path, this is the main path, not a corner case. **Fixed** (Fix A): a `*)` catch-all writes `needs-input` with a named-unrecognized-action question, never a silent claim-and-exit. The same shape was found and fixed in three more places: `ap-cycle.sh`'s external-failure requeue case (Fix E), `ap-resume.sh`'s DONE `if/elif` chain (Fix E), and tier 3's `phase_at_question` fallback (Fix C, below) — all four now fail closed to `needs-input`, mirroring the pattern `ap retry`'s `REQUEUE_STATE.get(phase)`-miss already uses elsewhere in this codebase, rather than inventing new shapes per site.

**Discriminator-adversarial-safety finding: `kind`'s read-time defaulting doesn't validate against `KINDS`.** `entry.get("kind") or DEFAULT_KIND` treats any present value as good enough as long as it's truthy — `"Bug"`, `"BUG"`, a stray `true`/`1` from a hand-edit or a future `ap queue` parsing bug all pass through unvalidated, silently failing every `== "bug"` check and running a bug ticket through the feature-plan path (no root-cause diagnosis step), invisible until the wrong artifact lands. **Fixed** (Fix D): `ticket_kind()` now validates against `KINDS` and defaults an invalid-but-present value exactly like a missing one, while a genuinely missing key still defaults to `feature` — no behavior change for any of today's tickets.

**Replay result: rows obtained.** The live queue (24 tickets) was read directly. Zero tickets carry a `kind` field today (expected — Phase 1 is unimplemented), so the replay gives no evidence about the `kind` branch itself; the branch is entirely unexercised by history. But the historical `phase_at_question` values include `implement` twice, and one of those — ticket ENG-1373 — is a real near-miss of the exact failure shape Fix C closes: a parked `implement`-phase question was answered while racing the stale-claim sweep, producing two false "stale, no active run" verdicts against a session that was still genuinely working, within one night. This is not hypothetical: it is the most fragile joint already in the system, and this plan's wider phase-name surface (`design`/`redesign`/`build` added to `investigate`/`re-investigate`/`fix`) makes it more likely to be hit again, not less, if the fallback isn't fixed. It costs nothing to fix now — `plan`/`replan`/absent are the only phase values that can currently reach tier 3 from a real dispatch, so making every *other* value fail closed changes no currently-reachable behavior.

**Blast radius**: every reader of `state`/`phase`/`action` that assumes a closed, enumerable set — `ap-cycle.sh`'s lane-lock case and its external-failure requeue case, `ap-resume.sh`'s DONE branch, `ap_queue.STATES` (now enforced by `transition()`, Fix B), and `ap-runs.py`'s four state tables (`QUEUE_DASHBOARD_STATES`, `_queue_note`, `TERMINAL_STATES`/`PENDING_STATES`, `REQUEUE_STATE`) — all already covered by this plan's rename/generalization tasks, now additionally hardened by Fixes A-E for the *unrecognized*-value case those tasks didn't originally address.

**Does the system already partially solve this? Yes, partially and inconsistently — the actionable finding.** `ap retry`'s `REQUEUE_STATE.get(phase)` miss already fails closed and loud today (`"don't know how to re-queue phase '<x>'"`). That is the sanctioned pattern this codebase already uses for exactly this class of problem; Fixes A, C and E just extend it to the three places that hadn't adopted it yet, rather than inventing a fourth shape.

**What a test would/wouldn't catch**: the pre-existing tier-5 test asserting the literal string `plan` will force a visible failure on this rename, which is good — it's the one guard that makes the change impossible to land silently wrong. Nothing in the original test tasks covered the claim-without-dispatch case, the fallback-with-a-present-garbage-value case, or an unswept new state. Three new cases are now added to close this: `test_decide.sh` items 14-15 (`kind="Bug"` resolves to feature not bug; an unrecognized `phase_at_question` produces `needs-input` not `replan`) and a new `test_cycle.sh` case (an unrecognized action does not leave a ticket claimed-but-undispatched).

## AMENDMENTS

<Append-only history of changes made to this plan AFTER it was first approved/executed. Leave empty at creation; newest entry at the bottom.>
