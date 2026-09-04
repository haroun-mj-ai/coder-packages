---
name: piv-implement
description: Executes an implementation plan task-by-task with validation at every step. Use when you have a completed feature plan and want to implement it in one pass.
argument-hint: [path-to-plan]
---

# Execute: Implement from Plan

## Plan to Execute

Read plan file: `$ARGUMENTS`

## Before you start — resume kata tracking, then work on a feature branch

**If this ticket has a Linear id** (`piv-plan-implementation` mirrors one into `kata` at planning time — see its
"Kata mirror" section): `kata search "ENG-<id>" --agent` and reuse it. `kata meta set <ref> work.attention ok --agent`
now that a build is starting. Whenever a stop condition below fires (interactively stopping-and-asking), also set
`kata meta set <ref> work.attention stuck|needs-human --agent` plus a one-line `work.attention_msg` — clear it back
to `ok` once resolved, and never leave the signal stale when you stop working this ticket. Kata unavailable or
errors for any reason other than "no match" → note it and continue; best-effort tracking, never a reason to stop.

A ticket gets built on its own branch, so it can become one PR. **Ideally you're already on that branch — cut it
before planning — so the plan commit you made is on it and rides into the PR; a plan committed on the base branch
won't be in this branch's PR.**

**Multi-repo tickets (this project):** `piv-plan-implementation` already created a worktree per involved repo,
named `wt-eng<id>-<suffix>`. Find and reuse them — never cut a second set:

```bash
for r in . backend frontend assistants; do
  git -C "$r" worktree list | grep "wt-eng<id>-" && echo "  ^ reuse this"
done
```

Work in whichever exist, **one repo at a time in dependency order, sequential within a repo** (two agents editing
the same checkout fight); independent repos (e.g. backend/frontend) can run concurrently. Before dispatching into a
reused worktree, verify it's actually fresh: `git -C <worktree> status --porcelain` must be empty (uncommitted
content there is a prior run's unfinished work, not junk — stop and ask rather than recreating it), and
`git -C <worktree> rev-list --count HEAD..origin/dev` must be `0` after a `fetch && rebase`.

**Single-repo ticket, or no tracker id at all** — the plain case, detect the base branch (don't hardcode `main`):
`git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'` (fallback `main`).

- **On the base branch, clean** → create one: `git checkout -b feature/<plan-slug>`.
- **Already on a feature branch or in a worktree** → use it.
- **On the base branch with uncommitted changes** → STOP: commit or stash first.

(One branch per ticket is also what makes parallel worktrees clean later.)

## Execution Instructions

**Model for task execution: sonnet, medium effort by default** — this project's `implementer` agent type is
pinned exactly for this: "execution half of a two-phase workflow, cheap and fast, once the design is settled."
The expensive reasoning already happened in `piv-plan-implementation` Phase 4 (opus); re-running that tier here
just to write code the plan already specified burns budget for no benefit. Default: dispatch each independent
task (or a small batch of dependent ones) via `Agent(subagent_type: "implementer")` rather than running every
task inline in the current session — same "cheap does the reading/writing, you do the judging" split as the rest
of this pipeline.

**Route self-contained/mechanical tasks to `codex-delegate` instead** (the `codex-feature` lane), not `implementer`
— a real, meaningful share of implementation work, not just Codex-side supplementary checks. A task qualifies
when it's bounded and clearly gated by the plan's own `VALIDATE` command, and doesn't ride on security,
concurrency, migration, or unstated domain knowledge the plan didn't spell out (the same bar `codex-delegate`'s
own docs use for "good delegation target" — if you're unsure whether a task qualifies, keep it on `implementer`).
Write the brief per `writing-the-brief.md`'s four-block shape (task / verification_loop naming this task's real
`VALIDATE` command / action_safety — no commit / structured_output_contract), dispatch:

```bash
node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane codex-feature
```

Background it, then **review exactly like any other completed task** — don't skip step 4's validation or the
spec-vs-plan check because Codex wrote it. `touchedFiles` should match the task's own file list, nothing wider.
This work goes through the same downstream gates as everything else (`piv-review-changes`, `debate-review` on the
PR) — delegating the writing doesn't change how it gets checked.

**Escalate rather than let the cheap model improvise**, the uncommon case only: if a task's own report says the
spec is wrong, a referenced hook/field doesn't exist, or the change doesn't fit as written — stop, don't let
`implementer` guess around it. Either fix it yourself with the plan in hand, or for something genuinely stuck
(not just "the spec was slightly off"), get an independent diagnosis via `codex-delegate --read-only` (the
`review-debate` lane): a brief naming what's stuck, what was tried, and what's unclear, same shape as
`piv-investigate-issue`'s "can't pin the root cause" recipe — no diff to review, just a second model's read on
the blocker. Rote/mechanical/boilerplate sub-tasks (e.g.
scaffolding a test file's structure) may go to a raw `Agent(model: "haiku")` call instead — this is a layer on
top of the `implementer` default, not a replacement of it; most tasks stay on `implementer`.

### 1. Read and Understand

- Read the ENTIRE plan carefully
- Understand all tasks and their dependencies
- Note the validation commands to run
- Review the testing strategy

### 2. Execute Tasks in Order

For EACH task in "Step by Step Tasks":

#### a. Navigate to the task
- Identify the file and action required
- Read existing related files if modifying

#### b. Implement the task
- Follow the detailed specifications exactly
- Maintain consistency with existing code patterns
- Include proper type hints and documentation
- Add structured logging where appropriate

#### c. Verify as you go
- After each file change, check syntax
- Ensure imports are correct
- Verify types are properly defined
- **Run the task's own `VALIDATE` command before starting the next task.** Every task in the plan carries one.
  A task is not done until its check passes — if it fails, fix it now rather than carrying the failure forward.
  The full suite still runs at step 4; this is the per-task gate that keeps step 4 from becoming a pile-up.

### 3. Implement Testing Strategy

After completing implementation tasks:

- Create all test files specified in the plan
- Implement all test cases mentioned
- Follow the testing approach outlined
- Ensure tests cover edge cases

### 3b. Adversarial test pass — Codex tries to break it

**Run this for every change** — Codex's side of this is a flat subscription, not metered spend, so there's no
cost reason to gate it the way a Claude dispatch would be. For a genuinely trivial/config-only change with no
real logic to attack, Codex reporting "nothing to test" is itself a fine, cheap outcome; that's still one more
piece of verification evidence, not a wasted dispatch. This is where Codex
adds genuine value rather than reviewing Claude's homework: cross-model review research (arXiv:2607.21656) found
Codex *reviewing* Claude-authored code makes it worse, but that study measured review verdicts — asking Codex to
**generate an attack** (a new failing test) is a different, generative task, not a grading task, and a test either
fails or it doesn't regardless of which model wrote it.

Use **`codex-delegate`**, not a one-shot forwarder — this is exactly its use case: the human (you, orchestrating)
reviews the diff it produces and lands it. Write a brief per its `writing-the-brief.md` shape and dispatch:

```xml
<task>
Try to find a real bug in this implementation by writing a test that breaks it: <point at the changed files/diff>.
If you find a genuine failing case, add the test at <this project's test dir, mirroring its structure> and report
what it exercises. If the implementation holds up under everything you tried, report that plainly.
</task>
<action_safety>
Only add a test file. Do NOT modify the implementation itself, and do NOT git add or commit — leave everything
in the working tree for review. If no real bug exists, don't force one.
</action_safety>
<structured_output_contract>
Report: (1) whether a genuine failing case was found, (2) the test file added if so, (3) what it exercises and
why it's real, or a plain statement that nothing was found.
</structured_output_contract>
```

```bash
node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane review-debate
```

Background it (`run_in_background: true`), then read `result.json`: `touchedFiles` should be exactly the one new
test file, nothing else — if it's not, that's scope creep, discard and re-dispatch tighter. If `status: failed`/
`codex_unavailable`, note it and move on; this step is a bonus check, not a gate.

If it produces a genuine failing test: fix the implementation to pass it, keep the test. If Codex reports nothing
found: note that in the implementation report (step 5's "Issues encountered" / this step counts as one more piece
of verification evidence, same as a passing test suite) and move on — a clean result here is a valid outcome, not
a sign the step should be skipped next time.

### 4. Run Validation Commands

Execute ALL validation commands from the plan in order:

```bash
# Run each command exactly as specified in plan
```

If any command fails:
- Fix the issue
- Re-run the command
- Continue only when it passes

### 5. Final Verification

Before completing:

- ✅ All tasks from plan completed
- ✅ All tests created and passing
- ✅ All validation commands pass
- ✅ Code follows project conventions
- ✅ Documentation added/updated as needed

## Output — write an implementation report

Write a short report to `.claude/reports/<plan-slug>-report.md` (and print the summary). This is what the PR body
and the `piv-review-pr` gate read — especially the **deviations** (a documented deviation is an *intentional*
decision the reviewer should not flag):

```markdown
# Implementation Report — <feature>

**Plan**: <path>   **Branch**: <feature/...>   **Status**: COMPLETE | PARTIAL

## Summary
{What was built, 2-4 sentences.}

## Tasks completed
- [task] → `path/to/file` (CREATE/UPDATE)

## Tests added
{Test files + cases + results.}

## Validation results
{Type-check / lint / tests / build — pass/fail with counts.}

## Deviations from the plan
{What changed vs the plan and WHY — or "none". This is the reviewer's signal of intent.}

## Issues encountered
{Anything notable, or "none".}
```

### Ready for the next step
- Confirm all changes are complete and validations pass.
- If tracking in kata, leave the ref open with `work.attention ok` — closing it happens only once a human has
  actually merged the PR, never from this skill.
- Next: `piv-commit` the work, then `piv-create-pr` to open the PR (the report fills the PR body), then `piv-review-pr`.

## Headless mode (--headless)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the
ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own
ask points map to.

**Phase**: `build`. `phase_at_question: "build"`. Invoked as `/piv-implement --headless --plan <path> --issue
ENG-<id> --ports fe=<n>,be=<m> --run-dir <d>`.

- **`--plan <path>` is always explicit.** A headless invocation without it is `FAILED`, `detail: "headless requires
  an explicit plan path"`, **no queue write** — mirroring `piv-implement-issue`'s `--rca` requirement exactly. The
  skill's interactive `Read plan file: $ARGUMENTS` contract (`:11`) does not survive headlessly: `$ARGUMENTS` is the
  full flag string, so the skill must **parse `--plan` out of it**, never treat `$ARGUMENTS` as a bare path.
- **`--issue ENG-<id>` is required.** This skill's own arguments carry a plan, not a ticket, and every queue write
  needs the ENG id — the identical situation Phase 1 already solved for `piv-review-pr` with the same
  headless-only token. It is therefore an **inherited convention, not a new flag**. The plan's filename encodes the
  id (`docs/plans/<ENG-ID>-<slug>.md`) and should be cross-checked against `--issue`; a mismatch is `FAILED`.

**This one act runs three skills.** After this skill's own steps complete, the same session runs **`/piv-commit`**
and then **`/piv-create-pr`**, and only then writes `status.json`. Neither has a human-judgment ask point
(`piv-commit` has none at all; `piv-create-pr`'s preconditions are deterministic fail-fast checks), so giving each
its own act would add two dispatches, two states and two park points for zero decision value.

**Re-entry must be idempotent** — a retried `build` act (external-failure requeue, or `ap retry`) re-enters from
`piv-draft-review`. Before implementing anything: if the ticket's branch already exists and already carries a
commit whose message contains `Part of ENG-<id>`, **skip to `/piv-create-pr`** rather than re-implementing;
`piv-create-pr`'s "existing PR already open → print the URL" precondition is then a `DONE`-idempotent success, not
a failure. Word-for-word the same rule Phase 1 gives `piv-implement-issue`, and for the same reason: without it a
retry re-implements work that already landed.

**Ask-point mapping table:**

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

**Report artifact path — headless overrides `.claude/reports/`.** Write to **`docs/plans/reports/<ENG-ID>-<slug>-report.md`**
in the worktree, `<slug>` being the plan file's own slug, **committed by `/piv-commit` as part of the implementation
commit.** This needed checking rather than copying Phase 1's answer, and the check confirms the same trap applies:
**`git status --porcelain .claude` in the work repo prints `?? .claude/reports/`** — untracked, not gitignored —
so a report written there is an uncommitted file that trips `piv-create-pr`'s own "Uncommitted changes → STOP"
precondition at the end of this very act. Two further reasons it must be in-repo and committed: it is the
reviewer's record of deviations and validation, which `piv-create-pr:57-59` and `piv-review-pr:34-38` both look
for and fold into the PR body and the deviation cross-check; and the *next* act (`review`) is a different session
that reads it from disk. Its absolute path goes in `status.json`'s `detail`. **Create `docs/plans/reports/` before
writing** — `docs/plans/` is tracked and exists in a fresh worktree, but `reports/` does not.

**`--ports fe=<n>,be=<m>`**: this skill starts no dev servers of its own, but step 4 runs "ALL validation commands
from the plan in order", and a plan's Level 4 Manual Validation legitimately can. If any command starts the
worktree servers: bind **exactly** those two ports (never the baseline 5173/8000), start the worktree backend with
`BACKEND_CORS_ORIGINS` set to a JSON list containing `http://localhost:<feport>` — this **replaces**, not extends,
the default allowlist — and **stop them before writing `DONE` *or* `NEEDS_HUMAN`** (a slot freed at park time can
be handed to a fresh act whose ports would collide). Verify with `ss -ltnp` before and after. In practice these
ports are usually unused, exactly as Phase 1 notes for the review lane; they are provisioned for isolation-safety
and consistency, and should not be documented as load-bearing for this lane the way they genuinely are for a
legacy `implement` act's browser QA.

**Rebase onto fresh base before opening the PR.** Between the last gate and `/piv-create-pr`: `git -C <worktree>
fetch` then `git -C <worktree> rebase origin/<base>`; if the rebase moved anything, **re-run the plan's validation
commands** before proceeding; a conflict is `FAILED` per the table. **Stated explicitly because it is a property
this cutover would otherwise lose**: the legacy chain got "rebased onto the latest dev and locally gate-clean"
from `/ship-work`, which no longer runs. `piv-review-pr` checks the PR out and runs the suite but does **not**
rebase. Recovering it here costs two commands inside an act that already has the worktree open.

**End state**: implement → tests → validate → scope/secrets gates → rebase → **`/piv-commit`** →
**`/piv-create-pr`** → `status.json` with `status: DONE`, `phase: "build"`, `artifact_path` = **the plan path,
unchanged from intake**, `pr_urls` filled with every opened PR URL, `detail` = the report path + the commit SHA +
the validation summary. Record on the ticket in one write: `--field pr_urls='["<url>"]' --event "implementation
committed <sha>, PR open"`. **Do not change the ticket's `state`** — it stays `piv-implementing`; the wrapper
swaps it to `piv-review-pending` after seeing this `DONE`. Same wrapper-owns-the-swap rule Phase 1 states for
`fix` and the legacy path states for `implement`.

**Pushing and opening PRs is pre-approved headlessly; nothing else loosens.** Never `main`, never a direct push to
`dev`, never a merge call, never a Linear comment, never a Linear state beyond the claim.

## Notes

- If you encounter issues not addressed in the plan, document them
- If you need to deviate from the plan, explain why
- If tests fail, fix implementation until they pass
- Don't skip validation steps
