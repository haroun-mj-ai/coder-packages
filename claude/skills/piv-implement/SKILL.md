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

## Notes

- If you encounter issues not addressed in the plan, document them
- If you need to deviate from the plan, explain why
- If tests fail, fix implementation until they pass
- Don't skip validation steps
