---
name: brief-ticket
description: Brief the user on a Linear ticket in plain English before any implementation decision gets made. Pulls the ticket plus everything it references, checks its claims against current code/PR/Linear ground truth (tickets go stale — "blocked on X" or "X doesn't exist yet" may no longer be true), explains the underlying product mechanism in plain language before any ticket jargon, and surfaces genuine cross-ticket conflicts or spec drift. Use when the user asks to understand, get briefed on, "explain", or get up to speed on a ticket/issue before deciding how to implement it. Do NOT use this to write a plan or implementation (that's plan-architecture / piv-plan-implementation) — this is understanding only.
---

# brief-ticket

Ticket text is a snapshot. By the time anyone reads it, some of what it says
may already be wrong — a blocker it names may have shipped, a "doesn't exist
yet" may now exist, a "revisit if X lands" clause may have silently triggered
and been missed. This skill's whole job is to close that gap before the human
has to reason about the ticket, not after.

## 1) Pull everything the ticket touches

Fetch the ticket itself (full body, not a summary) via the Linear MCP tools,
plus every issue it names as a blocker, dependency, sub-issue, or "related to"
— fetch those too, not just their titles. A ticket's own text is not the full
picture; half the useful information lives in what it points at.

## 2) Ground-truth every claim before trusting it

For each factual claim the ticket makes about the state of the world, check it
against reality instead of repeating it:

- **"Blocked on X"** — fetch X. Is it actually still open? (It may be Done with
  a merged PR while the blocking ticket still says "In Review.")
- **"X doesn't exist yet" / "not yet filed"** — search Linear for X by name.
  Tickets get filed after the blocker text is written and the blocker is never
  updated.
- **"Unwired, only test callers" / "no writer exists"** — grep the actual
  codebase for real (non-test) call sites, don't take the ticket's word for it.
- **A PR or "In Review" status** — check with `gh pr view` whether it's
  actually merged. Linear status lags merges routinely in this repo.
- **A conditional clause** ("if X lands first, revisit Y") — check whether X
  has in fact landed, and if so, whether Y was actually revisited anywhere
  (a comment, a follow-up ticket, a code change) or just silently missed.

Report what changed plainly: "the ticket says X, but as of today X is actually
Y" — with the evidence (file:line, PR #, Linear status field, date).

## 3) Explain the mechanism bottom-up, not the ticket top-down

Before using any ticket-specific vocabulary (spec names, work-unit IDs, step
numbers), explain what the feature actually does for a real user and why it
exists, in plain language, with a concrete example. Only once that mental
model is in place, map the ticket's jargon onto it. Someone should be able to
understand the explanation without having read the ticket first.

## 4) Check for cross-ticket conflicts, not just blockers

A ticket can be technically unblocked and still be about to duplicate or
contradict work a sibling/dependent ticket is doing — especially anything
touching the same write path, the same rule set, or the same cadence under a
different mechanism. This codebase has a known recurring bug class here
(duplicate-insight/action-item writes from two producers of the same signal —
see the ENG-936/ENG-1015 lesson cited across these tickets), so treat "does
something else already write this, on a different schedule or through a
different code path" as a first-class question, not an edge case.

## 5) Don't ask the human what you can find out yourself

Before presenting anything as an open question, check whether it's already
been answered somewhere: the referenced plan doc (`docs/plans/`), Linear
comments on the ticket and its relatives, git log / commit messages around
when the ambiguity would have been resolved, or a comment left directly in the
relevant code. Only surface something as a genuine open question if a real
search turned up nothing — and say what you checked, so the human knows it's
not a guess.

## 6) Output as prose, not a menu

Write the briefing as three sections in plain text: **what this actually does**
(the bottom-up explanation), **what's changed since this was written** (the
ground-truth corrections), and **what's genuinely still open** (questions with
no existing answer, explained in enough detail that the human can react in
their own words). Do not convert this into a sequence of multiple-choice
prompts — the point is for the human to think out loud in response, not pick
from a list.
