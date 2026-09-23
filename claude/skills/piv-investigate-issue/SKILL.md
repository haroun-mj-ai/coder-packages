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

### 7. Adversarial gate — ONLY when a trigger fires

**Order matters: challenge the diagnosis before red-teaming the fix — 7a is `/challenge`, 7b is `/red-team`.** A
challenge-driven revision to the root cause can change what the proposed fix actually does, which would make a
red-team pass run *before* that revision stale or wasted. Diagnosis gets stress-tested first; the fix derived from
it gets stress-tested second, after any revision the diagnosis check produced.

**7a. `/challenge` the root-cause reasoning — only when it rests on a measurement.** *Conditional.* **State plainly
that this trigger is a new convention introduced by this skill — `/challenge` has no existing wiring anywhere in
this codebase, so nothing here is inherited from a working precedent.** Trigger, made mechanically checkable: scan
the RCA's Evidence Chain (5 Whys) and Impact Assessment; if **any load-bearing link** cites something other than a
`file:line` reference — a count, a rate, a dashboard figure, a log volume, a query result, a time-window
comparison, a dataset conclusion — the trigger fires for that link. If every link is `file:line`, it does not.
Dispatch a fresh `Agent` carrying `/challenge`'s rubric with the claim written as one falsifiable sentence plus the
field/window/population it rests on, and **none of the reasoning that produced it**. Require back its report:
verdict, what was checked, the corrected claim if it changed, residual risk. **If the corrected claim changes the
root cause, revise "Proposed Fix" before 7b runs** — 7b must evaluate the (possibly revised) fix, not the
pre-challenge one.

**7b. `/red-team` the proposed fix — only when it touches a guard.** *Conditional. Skip it and say so unless the
trigger fires.* Trigger: the proposed fix changes the behaviour of any of — a verifier or postcondition, a
validator, a dispatcher/entry gate, a cap or budget check, a permission or entitlement check, a dedupe/idempotency
key, a retry or fallback branch, or a default deciding whether work happens at all. Classify from the RCA's own
"Files to Modify" and "Fix Strategy" sections; **when genuinely uncertain, run it.** Why this exists and the
cheaper check doesn't cover it: the RCA's own Confidence field asks "how sure am I of the cause?", which is a
different question from "what does this fix now let through?" — a HIGH-confidence RCA can carry a fix that turns
structurally-broken cases green. Dispatch a **fresh** `Agent` carrying `/red-team`'s rubric (model
`opus`, effort matching the RCA's Complexity), given: the fix stated as a behaviour delta ("after this change, X
will happen where Y happened before"), the guard's current code and tests, and **explicitly not the RCA's own
argument for why the fix is right**. Require back: the must-stay-fatal list, the discriminator attack, the replay,
the blast radius, and the already-solved check.

**Both**: fold findings into the RCA under the `## Adversarial review` section (below), **including a recorded
non-firing trigger, so every skip is auditable**. Verdict routing: red-team `do not ship as specified` or challenge
`does not survive` → **do not proceed to the RCA-ready state**; this is a blocking finding (headless mapping below).
`ship with the named additions` / `stands with caveats` → fold the additions into "Proposed Fix" and proceed.

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

## Headless mode (`--headless`)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the
ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own
ask points map to.

**Phase**: `investigate` (or `re-investigate` when `--feedback` is present). `phase_at_question: "investigate"`
on every `NEEDS_HUMAN`.

**Input is always an existing Linear issue id.** No free-text path headlessly.

**Worktree + branch mandate, first thing** — the single most important headless override, because the interactive
skill has no branch discipline at all and the main checkout is unusable: reuse the ticket's worktree if one exists
(`git worktree list | grep "wt-eng<id>-"`), else create `wt-eng<id>-root` (plus one per additional repo the RCA
touches) off the repo's real base (`dev` for root/`backend/`/`frontend/`, `main` for `assistants/`/`observability/`,
confirmed per repo, never assumed), on branch **`haroun/eng-<id>-fix-<slug>`**. Never work in the main checkout.
Three reasons, all verifiable: the main checkout is permanently dirty and typically sits on an unrelated branch, so
every dirty-tree and branch heuristic downstream mis-fires; `AP_BUILD_SLOTS > 1` means two acts must never share a
checkout; and the `dontAsk` profile only permits `git push -u origin haroun/*`, so any other prefix is denied at
push time.

**Linear claim + kata mirror, first thing**: claim (`assignee: me`, `state: In Progress`) and run step 1b's kata
search/create + `work.attention ok` + `work.branch haroun/eng-<id>-fix-<slug>`, unconditionally, `--feedback`
re-runs included (both are harmless no-ops when repeated). This is the only place the Linear claim can happen for
a bug ticket — `ap-decide.py` has no Linear credential. Mirrors `implement-issue/SKILL.md`'s own claim+kata step.

**Ask-point mapping table**:

| ask point | headless resolution | recorded as |
|---|---|---|
| Already closed | documented default: proceed, write the RCA anyway | `history` event `"issue already closed — RCA written anyway"`, plus `detail` |
| Already has a linked PR — *bare ask, no stated default; one is invented here* | documented default: **proceed** and record it, **unless** the linked PR is open and touches a file the RCA's own "Files to Modify" names — then `NEEDS_HUMAN`, quoting the PR URL and the overlapping files | `history` + `detail`; or `question` on the escalation |
| Can't pin the root cause / Confidence stays LOW after the Codex read-only corroboration attempt | already headless-shaped: write the RCA with the best hypothesis and what's uncertain, **and additionally** `NEEDS_HUMAN` — because the RCA's own Confidence:LOW is a hard stop for `piv-implement-issue`, so proceeding to `piv-draft-review` would only park the ticket one phase later having spent a whole fix act to rediscover it | `question` = the specific unknown that would raise confidence; kata `work.attention needs-human` |
| Scope too large | documented default: keep the RCA on the core problem, list the rest as out-of-scope; do not split, do not create Linear issues (creation is interactive-only per the protocol) | `detail` + the RCA's own out-of-scope list |
| Step 7a challenge `does not survive`, or 7b red-team `do not ship as specified` | `NEEDS_HUMAN` — never a silent override | `question` = the verdict plus the single most load-bearing finding; the full findings live in the RCA's `## Adversarial review`; kata `work.attention needs-human` |
| Linear comment step | **skipped entirely** — headless runs never post a Linear comment, and `mcp__linear-server__save_comment` is not even on the allow list | n/a |

**Commit the RCA before the queue write.** The RCA must be committed on the ticket's branch in its worktree — the
fix act is a different session, potentially hours later, and reads it from disk; an uncommitted artifact would
also leave the worktree dirty and trip the fix act's own precondition checks. Same discipline as the plan phase
committing its plan.

**End state**: after the commit, one write —
```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state piv-draft-review \
  --field artifact_path=/absolute/path/to/docs/issues/issue-<ENG-ID>.md \
  --event "RCA ready for review"
```
then `status.json` with `status: DONE`, `phase: "investigate"`, `artifact_path` = the RCA path. **Without this
write the ticket never leaves `piv-drafting` and the pipeline stalls after every investigation** — do not skip it
or reorder it before the commit lands.

**`--feedback '<text>'`**: treat as new information about the bug, not a mechanical correction. Revise the RCA in
place (same file, same branch, a new commit) and **re-run step 7's triggers against the revision** — a revised fix
strategy can newly touch a guard, or newly lean on a metric. Then re-record `artifact_path` and write `DONE` as
above.
