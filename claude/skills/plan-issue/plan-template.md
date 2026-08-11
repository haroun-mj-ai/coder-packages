# <Title>

- **Ticket:** ENG-<id>
- **Status:** Draft | Approved | In Progress | Completed
- **Repos touched:** root / backend / frontend / assistants
- **Date:** YYYY-MM-DD

## Context

Why this is being done: the problem or need, what prompted it, and the intended
outcome. Two or three paragraphs, no more. Someone picking this up in three weeks
should understand the motivation without opening Linear.

## Current state

What the code does today, with evidence. Every claim gets a `path:line` so the
plan can be dry-run reviewed and so the implementer can jump straight there.

- `backend/app/api/v1/foo.py:112`: the handler resolves X before Y, which is why
  the symptom appears only on the second sync.
- `frontend/src/features/bar/useBaz.ts:44`: the hook caches on mount and never
  invalidates.

**What does not exist** (from exploration, and the section that keeps the
plan from being built on an assumption):

- There is no `on_stage_change` hook; stage transitions are only observable via
  the reconcile pass.

## Approach

The chosen design, stated plainly. One approach, not a survey. If a leading
alternative was rejected, one line on why, enough to stop the question being
re-litigated, not a comparison essay.

## Work units

Each unit is dispatched to a single implementation agent that has not seen the
planning conversation. It must be independently executable from what is written
here. Sized to one context window: if it needs reading more than ~15 files or
touching more than ~5, split it.

### U1: <name>

- **Repo:** `backend/`
- **Depends on:** none
- **Files:** `app/services/foo.py`, `app/models/bar.py`
- **Change:** what to do, specifically enough that there is nothing to invent.
  Name the function, the field, the return shape.
- **Tests:** `tests/test_foo.py::test_stage_order_survives_resync`, fails before,
  passes after. Assert the behavior the Context section describes, not the shape
  of the implementation.
- **Done when:** `poetry run pytest tests/test_foo.py` is green.

### U2: <name>

- **Repo:** `frontend/`
- **Depends on:** U1 (needs the new field on the response)
- ...

## Test strategy

How the three points of truth line up: this plan, the tests, the code. Name the
commands that will be run and what a pass actually proves. Call out anything that
cannot be covered deterministically and will need manual or browser QA instead.

## Edge cases

The 90% happy path is covered by the work units above. These are the cases that
break naive implementations:

- Empty / first-run state, exactly one item, and past whatever cap exists.
- The value already exists and is stale.
- Two orgs, one of which lacks the integration.
- Adding an enum member: the matching defaults map and the test asserting the
  member count both have to be updated or the full suite fails.

## Interaction surface

What else touches what this change touches. Name it here at plan time, because it
is cheaper to design for than to discover during QA, and `/implement-plan` will
derive this list from the diff anyway. From exploration, with `path:line`:

- **Other consumers** of every function, component, hook, endpoint, model field, or
  query key being changed. A changed TanStack Query key serves stale data to views
  nobody edited.
- **Tenancy.** Anything org- or workspace-scoped: state how isolation is preserved.
  Cross-workspace and org-wide visibility leaks are a repeat failure class here.
- **Roles.** Does this read differently for a manager, a rep, or staff?
- **Real-time.** Does a WebSocket event, reconnect, or a second open tab affect it?
- **Layout.** Which existing view does the new element live inside, and does it
  still fit at a narrow width?

Say "none" only after checking, and say what you checked.

## Risks and open questions

- **BLOCKING**: <question that must be answered before code is written>.
  `/implement-plan` will refuse to run while this is unresolved.
- Non-blocking: <thing to decide during or after the build>, with the assumption
  being proceeded on if unanswered.

## Verification

How to prove this works end to end, not just that the unit tests pass:

1. Quality gates: `cd frontend && npm run build && npm run test:run`,
   `cd backend && poetry run pytest`.
2. The real user path: what to click or curl, in what order, and what should be
   seen. Note if the local dev server serves the main checkout's branch rather
   than a worktree.
3. What to check in staging after merge, and what would indicate a regression.

## Out of scope

What was deliberately left out, so the reviewer knows it was a decision rather
than an oversight. Anything worth doing later gets its own follow-up ticket.

## Design review

Filled in after the `plan-critic` dry run, before the human reads this.

- **Verdict:** SOUND | SOUND WITH FIXES | DO NOT IMPLEMENT
- **Raised and fixed:** <what was wrong, and what the plan now says instead>
- **Raised and rejected:** <finding, and the reason it does not apply>
- **Could not be checked:** <anything the critic could not verify>
