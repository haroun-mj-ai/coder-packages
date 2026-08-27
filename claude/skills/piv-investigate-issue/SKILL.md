---
name: piv-investigate-issue
description: Investigate a Linear issue — fan out parallel exploration, find the root cause (5 Whys, evidence-backed), and write a reviewable RCA artifact (then post a summary as a Linear comment). The investigate step before piv-implement-issue. Use to diagnose a bug/issue before fixing it.
argument-hint: [linear-issue-id]
---

# Investigate Issue $ARGUMENTS (Root-Cause Analysis)

## Objective

Investigate Linear issue $ARGUMENTS (e.g. `ENG-123`), identify the root cause, and document findings for future implementation.

**Prerequisites:**
- Working in one of this project's git repos (root, `backend/`, `frontend/`, `assistants/`)
- Linear MCP available
- Valid Linear issue id

## Investigation Process

### 1. Fetch Linear Issue Details

```
mcp__linear-server__get_issue        # description, acceptance criteria, status, labels
mcp__linear-server__list_comments    # discussion — requirements/repro steps are often only here
```

This fetches:
- Issue title and description
- Reporter and creation date
- Labels and status
- Comments and discussion

### 1b. Kata mirror — local step-ledger

This is the entry point for bug work, so it's where the ticket's `kata` step-ledger entry gets created (mirrors
`piv-plan-implementation`'s convention for features):

- `kata search "$ARGUMENTS" --agent` first — reuse an existing entry rather than duplicating.
- If none: `kata create "$ARGUMENTS: <title>" --body "<will hold the RCA path once written>" --idempotency-key "$ARGUMENTS" --agent`.
- Either way: `kata meta set <ref> work.attention ok --agent`.
- Kata unavailable, or errors for any reason other than "no match" — note it and continue; best-effort tracking.

### 2. Explore the Codebase — fan out in parallel

Dispatch specialized agents **in parallel** (one message, multiple Agent calls) so exploration is fast and the
noisy search stays out of your main context. Model-tiered by what each one actually has to do:
- **`codebase-analyst`** — trace HOW the affected code works end-to-end: integration points, data flow,
  state/side effects, error handling. This is tracing + judgment about what matters, not a flat lookup — dispatch
  as `Agent(subagent_type: "explorer")` (sonnet, medium). Return precise `file:line` references, no suggestions.
- **`research-agent`** (a second explorer) — find WHERE the relevant code lives + patterns to mirror: the error
  strings from the issue, related functions/modules, similar implementations, existing test patterns. This is a
  mechanical "where/which files" lookup — dispatch as `Agent(subagent_type: "scout")` (haiku, low).

Merge their findings into a short map (`file:line` + why each matters) before forming the root cause. *(This is
the parallel-subagent fan-out, applied to diagnosis.)* The 5-Whys synthesis itself (step 4, below) stays with you
— the main session does the judging, subagents only did the reading.

### 3. Review Recent History — when was it introduced?

Check recent changes to the affected areas, and pin down when the bug entered:
!`git log --oneline -20 -- [relevant-paths]`
```bash
git blame -L <start>,<end> <affected-file>   # who/when introduced the suspect lines
```
Decide: a recent **regression** vs a **long-standing** bug vs **original** behavior — it changes both the fix and the risk.

### 4. Investigate Root Cause — the 5 Whys, with evidence

Don't stop at the symptom. Chain **why → because** until you reach the specific, fixable code, and back **every link
with `file:line` evidence**:
```
WHY does <symptom> happen? → because <cause A>   (evidence: file.ts:123 — <snippet>)
WHY <cause A>?             → because <cause B>   (evidence: file.ts:456 — <snippet>)
… ROOT CAUSE: <the exact code/logic to change>  (evidence: file.ts:789 — <snippet>)
```
Watch for: input-validation gaps, unhandled edge cases, race/timing issues, wrong assumptions, missing error
handling, integration mismatches.

### 5. Assess Impact

**Determine:**
- How widespread is this issue?
- What features are affected?
- Are there workarounds?
- What is the severity?
- Could this cause data corruption or security issues?

### 6. Propose Fix Approach

**Design the solution:**
- What needs to be changed?
- Which files will be modified?
- What is the fix strategy?
- Are there alternative approaches?
- What testing is needed?
- Are there any risks or side effects?

## Output: Create RCA Document

Save analysis as: `docs/issues/issue-$ARGUMENTS.md` in the **root repo** even when the affected code lives in
`backend/`/`frontend/`/`assistants/` — one doc per ticket, file paths inside it point wherever the code actually is.

### Required RCA Document Structure

```markdown
# Root Cause Analysis: Linear Issue $ARGUMENTS

## Issue Summary

- **Linear Issue ID**: $ARGUMENTS
- **Issue URL**: [Link to Linear issue]
- **Title**: [Issue title from Linear]
- **Reporter**: [Linear user]
- **Status**: [Current Linear issue state]

## Assessment

Each value needs a one-line reason grounded in the investigation (not a guess):

| Metric | Value | Reasoning |
|--------|-------|-----------|
| Severity | Critical/High/Medium/Low | user impact · workaround · scope of failure |
| Complexity | Low/Medium/High | files touched · integration points · risk |
| Confidence | High/Medium/Low | evidence quality · unknowns · assumptions |

> **Confidence is the human-attention signal:** LOW confidence = a human should look before the fix runs. Say it honestly.

## Problem Description

[Clear description of the issue]

**Expected Behavior:**
[What should happen]

**Actual Behavior:**
[What actually happens]

**Symptoms:**
- [List observable symptoms]

## Reproduction

**Steps to Reproduce:**
1. [Step 1]
2. [Step 2]
3. [Observe issue]

**Reproduction Verified:** [Yes/No]

## Root Cause

### Affected Components

- **Files**: [List of affected files with paths]
- **Functions/Classes**: [Specific code locations]
- **Dependencies**: [Any external deps involved]

### Analysis

[Detailed explanation of the root cause]

**Evidence Chain (5 Whys):**
```
WHY <symptom> → because <cause>          (evidence: file:line — snippet)
… ROOT CAUSE: <the exact fixable thing>  (evidence: file:line — snippet)
```

**Why This Occurs:**
[Explanation of the underlying issue]

**Code Location:**
```
[File path:line number]
[Relevant code snippet showing the issue]
```

### Related Issues

- [Any related issues or patterns]

## Impact Assessment

**Scope:**
- [How widespread is this?]

**Affected Features:**
- [List affected features]

**Severity Justification:**
[Why this severity level]

**Data/Security Concerns:**
[Any data corruption or security implications]

## Proposed Fix

### Fix Strategy

[High-level approach to fixing]

### Files to Modify

1. **[file-path]**
   - Changes: [What needs to change]
   - Reason: [Why this change fixes it]

2. **[file-path]**
   - Changes: [What needs to change]
   - Reason: [Why this change fixes it]

### Alternative Approaches

[Other possible solutions and why the proposed approach is better]

### Risks and Considerations

- [Any risks with this fix]
- [Side effects to watch for]
- [Breaking changes if any]

### Testing Requirements

**Test Cases Needed:**
1. [Test case 1 - verify fix works]
2. [Test case 2 - verify no regression]
3. [Test case 3 - edge cases]

**Validation Commands:**
```bash
[Exact commands to verify fix]
```

## Implementation Plan

[Brief overview of implementation steps]

This RCA document should be used by the `piv-implement-issue` skill.

## Next Steps

1. Review this RCA document
2. Run the `piv-implement-issue` skill with issue #$ARGUMENTS to implement the fix
3. Run the `piv-commit` skill after implementation complete
```

## Post the summary to the issue

After writing the doc, post a short version as a Linear comment — an audit trail, and so the fix can be
triggered/tracked from the issue itself. Bullet lists, not a markdown table — Linear corrupts tables with
backticked cells:

```
mcp__linear-server__save_comment  issueId=$ARGUMENTS
body: "<title · severity/complexity/confidence as bullets with one-line reasons · root cause in 1-2 lines ·
       files to change · next: /piv-implement-issue $ARGUMENTS>"
```

Re-read the response to confirm the comment landed.

Also update the kata ref from step 1b now that the RCA path is known: `kata comment <ref> --message "RCA: <path>"
--agent`. Leave `work.attention ok` — `piv-implement-issue` resumes this same ref when the fix is built.

## Edge cases

- **Already closed** → report it; still write the RCA if analysis is wanted.
- **Already has a linked PR** → warn; confirm before continuing.
- **Can't pin the root cause** → before settling for **Confidence: LOW**, get a genuinely independent read via
  `codex-delegate`'s `--read-only` mode (the `review-debate` lane already configured):
  ```xml
  <task>
  Investigate the root cause of: <issue summary>. Evidence found so far: <what you found>. Unresolved:
  <what's unclear>. This is investigation only — do not fix anything, just report findings.
  </task>
  <grounding_rules>Ground every claim in evidence; label anything that's an inference.</grounding_rules>
  ```
  ```bash
  node "<codex-delegate skill-dir>/scripts/relay.mjs" --brief brief.txt --cd <repo path> --lane review-debate --read-only
  ```
  If it independently converges on the same cause (read `result.json`'s `finalMessage`), that's real corroboration
  and confidence can go up; if it disagrees or also can't pin it, that itself is useful evidence for LOW. Either
  way, document the best hypothesis + what's uncertain, and
  flag it for a human before any fix.
- **Scope too large** → suggest splitting into smaller issues; focus this RCA on the core problem and list the rest as out-of-scope.
