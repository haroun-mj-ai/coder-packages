---
name: piv-implement-issue
description: Implement the fix for a Linear issue from its RCA artifact (created by piv-investigate-issue) — drift-check the plan, branch, implement, add regression tests, and validate. Use after the investigation artifact exists and you're ready to fix the issue.
argument-hint: [linear-issue-id]
allowed-tools: Read, Write, Edit, Bash(ruff:*), Bash(mypy:*), Bash(pytest:*), Bash(npm:*), Bash(bun:*)
---

# Implement Issue Fix: Linear Issue $ARGUMENTS

## Prerequisites

**This skill implements fixes for Linear issues based on RCA documents:**
- Working in one of this project's git repos (root, `backend/`, `frontend/`, `assistants/`)
- RCA document exists at `docs/issues/issue-$ARGUMENTS.md` (in the root repo)
- Linear MCP available (for status/comment updates)

## RCA Document to Reference

Read RCA: `docs/issues/issue-$ARGUMENTS.md`

**Optional - view the Linear issue for context:**
```
mcp__linear-server__get_issue   id=$ARGUMENTS
```

## Implementation Instructions

### 0. Resume kata tracking

`piv-investigate-issue` mirrors the ticket into `kata` when the RCA is written. Resume it: `kata search
"$ARGUMENTS" --agent`, reuse the ref. `kata meta set <ref> work.attention ok --agent` now that a fix build is
starting. Whenever a stop condition below fires, also `kata meta set <ref> work.attention stuck|needs-human --agent`
plus a one-line `work.attention_msg`, and clear it back to `ok` once resolved — never leave the signal stale. If
no kata ref exists yet (an RCA predating this convention), create one the same way
`piv-investigate-issue` does. Kata unavailable or erroring for any reason other than "no match" → note it, continue.

### 1. Read and Understand RCA

- Read the ENTIRE RCA document thoroughly
- Review the Linear issue details (issue $ARGUMENTS)
- Understand the root cause
- Review the proposed fix strategy
- Note all files to modify
- Review testing requirements

### 2. Verify Current State — and check for drift

Before making changes:
- Confirm the issue still exists.
- **Drift check:** read each file the RCA names and compare against the RCA's "current code" snippets / line refs.
  If the code has **changed materially** since the RCA, **stop** (kata: `work.attention needs-human`, message
  "RCA drifted from current code") — surface the drift and suggest re-running `piv-investigate-issue` for issue
  $ARGUMENTS rather than implementing a stale plan.
- Confirm the proposed fix still addresses the root cause — don't silently deviate.

### 2b. Get on the right branch

- **RCA touches more than one repo?** Reuse the ticket's worktrees (`wt-eng<id>-<suffix>`, one per involved repo —
  see `piv-plan-implementation`'s multi-repo section / `worktree-create`) rather than branching in the main
  checkout of each.
- **In a worktree already?** Use it (it was created for this work).
- **On the base branch, clean tree, single repo?** Create a fix branch — `git checkout -b fix/issue-$ARGUMENTS-<slug>`
  (detect the base with `git symbolic-ref refs/remotes/origin/HEAD`; root/`backend/`/`frontend/` → `dev`,
  `assistants/`/`observability/` → `main`, never assume).
- **Already on a feature/fix branch?** Use it (warn if its name doesn't reference $ARGUMENTS).
- **Dirty tree on the base branch?** Stop — ask the user to commit or stash first.

### 3. Implement the Fix

**Model: sonnet, medium effort by default** (`Agent(subagent_type: "implementer")` if delegating rather than
implementing inline) — the RCA already did the expensive reasoning; this step turns a settled fix strategy into
code. **Scale up using the RCA's own Assessment table**, which already scored this: Complexity **High** → escalate
to a raw `Agent(model: "opus", effort: "high")` instead (a fix strategy touching several integration points
deserves the higher tier); Confidence **Low** → don't implement from this RCA at all without confirming the root
cause first (this is what step 2's drift-check and `piv-investigate-issue`'s Codex-corroboration edge case are
for) — a low-confidence RCA implemented at any model tier is still building on a guess.

Following the "Proposed Fix" section of the RCA:

**For each file to modify:**

#### a. Read the existing file
- Understand current implementation
- Locate the specific code mentioned in RCA

#### b. Make the fix
- Implement the change as described in RCA
- Follow the fix strategy exactly
- Maintain code style and conventions
- Add comments if the fix is non-obvious

#### c. Handle related changes
- Update any related code affected by the fix
- Ensure consistency across the codebase
- Update imports if needed

**Stay on plan:** implement what the RCA specifies — don't refactor unrelated code or add unplanned
"improvements." If you must deviate, note what changed and why, and surface it in the report (and the PR).

### 4. Add/Update Tests

Following the "Testing Requirements" from RCA:

**Create test cases for:**
1. Verify the fix resolves the issue
2. Test edge cases related to the bug
3. Ensure no regression in related functionality
4. Test any new code paths introduced

**Test file location:**
- Follow project's test structure
- Mirror the source file location
- Use descriptive test names

**Test implementation:**
```python
def test_issue_$ARGUMENTS_fix():
    """Test that issue #$ARGUMENTS is fixed."""
    # Arrange - set up the scenario that caused the bug
    # Act - execute the code that previously failed
    # Assert - verify it now works correctly
```

### 4b. Adversarial test pass — Codex tries to prove the bug isn't actually fixed

This is where a bug fix benefits from Codex the most: not grading the fix (the harmful review direction — see
`piv-review-pr`'s notes on arXiv:2607.21656), but genuinely trying to break it, which is generative work, not a
verdict on Claude's code. Use `codex-delegate` (the `review-debate` lane already configured) rather than a
one-shot forwarder — you review and land whatever it produces, same as `piv-implement`'s Phase 3b:

```xml
<task>
This is a fix for: <RCA root cause, one line>. Here's the fix: <diff>. Try to find a variation of the original bug
this fix doesn't actually cover — an adjacent edge case, a different code path that hits the same root cause, or
a case the fix's own test doesn't exercise. If you find one, write a failing test for it at <test path>.
</task>
<action_safety>
Only add a test file. Do NOT modify the fix itself, and do NOT git add or commit. If the fix genuinely holds up,
say so plainly — don't force a failing case that isn't real.
</action_safety>
<structured_output_contract>
Report: (1) whether a real gap was found, (2) the test file added if so, (3) why it's a genuine variation of the
original bug, not the same case restated.
</structured_output_contract>
```

```bash
node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane review-debate
```

Background it, read `result.json`, confirm `touchedFiles` is exactly the one new test file. A genuine failing test
here means the fix is incomplete — go back to step 3 with the specific gap, not just the original RCA. Nothing
found is a valid, useful result — record it in the report as one more piece of verification. `status: failed`/
`codex_unavailable` → note it and move on, this is a bonus check, not a gate.

### 5. Run Validation

Execute validation commands from RCA:

```bash
# Run linters
[from RCA validation commands]

# Run type checking
[from RCA validation commands]

# Run tests
[from RCA validation commands]
```

**If validation fails:**
- Fix the issues
- Re-run validation
- Don't proceed until all pass

### 6. Verify Fix

**Manually verify:**
- Follow reproduction steps from RCA
- Confirm issue no longer occurs
- Test edge cases
- Check for unintended side effects

### 7. Update Documentation

If needed:
- Update code comments
- Update API documentation
- Update README if user-facing
- Add notes about the fix

## Output Report

### Fix Implementation Summary

**Linear Issue $ARGUMENTS**: [Brief title]

**Issue URL**: [Linear issue URL]

**Root Cause** (from RCA):
[One-line summary of root cause]

### Changes Made

**Files Modified:**
1. **[file-path]**
   - Change: [What was changed]
   - Lines: [Line numbers]

2. **[file-path]**
   - Change: [What was changed]
   - Lines: [Line numbers]

### Tests Added

**Test Files Created/Modified:**
1. **[test-file-path]**
   - Test cases: [List test functions added]

**Test Coverage:**
- ✅ Fix verification test
- ✅ Edge case tests
- ✅ Regression prevention tests

### Validation Results

```bash
# Linter output
[Show lint results]

# Type check output
[Show type check results]

# Test output
[Show test results - all passing]
```

### Verification

**Manual Testing:**
- ✅ Followed reproduction steps - issue resolved
- ✅ Tested edge cases - all pass
- ✅ No new issues introduced
- ✅ Original functionality preserved

### Deviations from the RCA

[None — implemented as specified | List each deviation from the RCA + why]

### Files Summary

**Total Changes:**
- X files modified
- Y files created (tests)
- Z lines added
- W lines removed

### Ready for Commit

All changes complete and validated. Ready for the `piv-commit` skill. If tracking in kata, leave the ref open
with `work.attention ok` — closing it happens only once a human has actually merged the fix, never from here.

**Suggested commit message:**
```
fix(scope): resolve issue $ARGUMENTS - [brief description]

[Summary of what was fixed and how]

Part of $ARGUMENTS
```

**Note:** deliberately `Part of $ARGUMENTS`, never `Fixes`/`Closes`/`Resolves` — this project's convention (see
AGENTS.md) is that a human, not a commit message, marks a Linear issue `Done` once they've actually reviewed and
merged the fix.

### Optional: Update the Linear issue

**Add implementation comment to issue:**
```
mcp__linear-server__save_comment  issueId=$ARGUMENTS
body: "Fix implemented in commit [commit-hash]. Ready for review."
```

**Never set state to `Done` from here** — leave it to whoever reviews/merges the PR, per this project's Linear
convention.

## Headless mode (`--headless`)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the
ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own
ask points map to.

**Phase**: `fix`. `phase_at_question: "fix"`. **`--rca <path>` is always explicit**; a headless invocation
without it is `FAILED`, `detail: "headless requires an explicit RCA path"`, no queue write.

**This one act runs three skills.** After this skill's own steps complete, the same session runs **`/piv-commit`**
and then **`/piv-create-pr`**, and only then writes `status.json`. Neither has a human-judgment ask point
(`piv-commit` has none at all; `piv-create-pr`'s preconditions are deterministic fail-fast checks), so giving each
its own act would add two dispatches, two states, and two park points for zero decision value.

**Re-entry must be idempotent** — a retried `fix` act (external-failure requeue, or `ap retry`) re-enters from
`piv-draft-review`. Before implementing anything: if the ticket's branch already exists and already carries a
commit whose message contains `Part of ENG-<id>`, **skip to `/piv-create-pr`** rather than re-implementing.
`piv-create-pr`'s own "existing PR already open → print the URL" precondition is then a `DONE`-idempotent success,
not a failure. Without this rule a retry re-implements a fix that already landed.

**Ask-point mapping table**:

| ask point | headless resolution | recorded as |
|---|---|---|
| RCA drift check (`:46-54`) — hard stop | `NEEDS_HUMAN`, `question` = the drifted files with the RCA's expected vs actual, and "re-run `/piv-investigate-issue ENG-<id>`" | `question`, kata `needs-human`, `work.attention_msg` |
| Confidence:Low in the RCA's Assessment table (`:73-76`) — hard stop, machine-checkable | `NEEDS_HUMAN` **before any code is written**: read the RCA's Confidence field first, branch on it | `question` = "RCA confidence is LOW; the root cause needs confirming before a fix" |
| Branch selection (`:56-66`) | **overridden entirely**: reuse the worktree/branch `piv-investigate-issue` created (`haroun/eng-<id>-fix-<slug>`); if it is missing, create it the same way rather than falling through to the interactive heuristics | `history` event on a re-create |
| Dirty tree on the base branch (`:66`) — bare ask, no stated default | **`FAILED`**, `detail` = the `git status -sb` output. Auto-choosing commit-or-stash silently mutates a human's uncommitted work, the one class of action this protocol exists to prevent; and `NEEDS_HUMAN` is the wrong shape because the remedy is git work at a terminal, which the `ap reply` channel cannot express — it would park a tmux window indefinitely. `FAILED` is the state whose semantics are "an error stopped the run; the wrapper decides whether to retry", and `ap retry` recovers it once the tree is clean. Given the worktree mandate, a dirty tree here means a dirty *worktree* — a prior run's leftovers, which is genuinely worth pausing on (note: this increments `fail_count` and can auto-pause after two) | `detail` |
| Deviating from the RCA's plan (`:97-98`) | documented default: implement as specified; a forced deviation is recorded in the report's "Deviations from the RCA" section and in `detail`, never a stop | report + `detail` |
| Validation fails (`:171-175`) | documented default: fix and re-run (bounded — after two full failing cycles, `NEEDS_HUMAN` with the failing output) | `question` on escalation |
| Codex adversarial test pass (`:124-154`) | unchanged: a bonus check. `status: failed`/`codex_unavailable`/permission-denied → note in `detail` and move on. A genuine failing test means the fix is incomplete → back to step 3 with the specific gap, still inside this act | `detail` |
| Linear implementation comment (`:276-282`) | **skipped** — never a Linear comment headlessly | n/a |
| Linear state `Done` (`:284-285`) | already correct: never | n/a |

**Report artifact path.** The output report (`:192-274`) gets a fixed path headlessly:
**`docs/issues/reports/<ENG-ID>-fix-report.md`**, in the worktree, **committed by `/piv-commit` as part of the fix
commit**. It must be inside the repo and committed, because (a) it is the reviewer's record of deviations and
validation, which `piv-create-pr:57-59` already looks for and folds into the PR body, and (b) an uncommitted file
would leave the tree dirty and trip `piv-create-pr`'s own "Uncommitted changes → STOP" precondition. This is
`docs/issues/reports/`, not `.claude/reports/` — the latter is untracked in this work repo and would produce
exactly that dirty-tree trap. Its absolute path goes in `status.json`'s `detail`, mirroring the QA-artifact
convention (`implement-issue/SKILL.md:1276-1282`).

**`--ports fe=<n>,be=<m>`**: if step 6's manual reproduction check starts the worktree servers, bind exactly those
two ports (never the baseline 5173/8000) and start the worktree backend with `BACKEND_CORS_ORIGINS` set to a JSON
list containing `http://localhost:<feport>` — this **replaces**, not extends, the default allowlist. **Stop them
before writing `DONE` *or* `NEEDS_HUMAN`** (the protocol's parking rule: a slot freed at park time can be handed
to a fresh act whose ports would collide). Verify with `ss -ltnp` before and after. Browser QA and the
four-server baseline comparison are **not** required for the bug path — the fix's evidence is its reproduction
case plus its regression test.

**End state**: implement → tests → validate → **`/piv-commit`** → **`/piv-create-pr`** → `status.json` with
`status: DONE`, `phase: "fix"`, `artifact_path` = the RCA path, `pr_urls` filled, `detail` = the fix-report path +
the commit SHA. Record on the ticket in one write: `--field pr_urls='["<url>"]' --event "fix committed <sha>, PR
open"`. **Do not change the ticket's `state`** — it stays `piv-implementing`; the wrapper swaps it to
`piv-review-pending` after seeing this `DONE`.

## Notes

- If the RCA document is missing or incomplete, request it be created first with the `piv-investigate-issue` skill for issue $ARGUMENTS
- If you discover the RCA analysis was incorrect, document findings and update the RCA
- If additional issues are found during implementation, note them for separate Linear issues and RCAs
- Follow project coding standards exactly
- Ensure all validation passes before declaring complete
- The commit message says `Part of $ARGUMENTS`, never `Fixes` — a human marks the Linear issue Done, not the commit
