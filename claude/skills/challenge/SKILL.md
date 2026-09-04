---
name: challenge
description: Stress-test a claim, number, dataset, or conclusion BEFORE acting on it or publishing it — interrogate where the data came from, whether the instrument that produced it is trustworthy, whether the measurement window is clean, and whether the thing counted means what it is assumed to mean. Runs the interrogation in a fresh sub-agent that never sees the reasoning behind the claim, so it cannot rubber-stamp it. Use before filing a ticket off an analysis, before quoting a figure to someone, before sizing work off a metric, or whenever a number is about to become a decision. Do NOT use to review code for bugs (that is /code-review) or to attack a proposed fix (that is /red-team).
---

# challenge

A claim is not wrong because the arithmetic is wrong. It is wrong because the
**instrument** was wrong, the **window** was dirty, or the thing counted did not
mean what it was assumed to mean. This skill attacks those three before the claim
becomes a decision.

**Not this skill's job:** finding bugs in code (`/code-review`), attacking a
proposed solution (`/red-team`), or judging whether a finding is worth acting on.
This decides only whether the finding is *true*.

---

## 0) Pin the claim down

Write the claim as one falsifiable sentence, with its numbers, before anything
else. If it cannot be written that way, that is the finding — vague claims cannot
be checked and must not be published.

Then state, for each number in it:
- the **field or source** it came from (exact name, exact path)
- the **window** it covers (precise start and end)
- the **population** it covers (which users, orgs, specs, rows)

If any of those three is unknown, stop and find it. Most bad claims die here.

---

## 1) The instrument — is this the source of truth or a convenience copy?

The single highest-yield question. **A field that sits conveniently on the
document you already loaded is the one most likely to be derived, stale, or
partial.**

- **Who WRITES this field?** Find the write site. Is it authoritative, or is it
  re-derived from something else?
- **Is there a lower-level ledger?** Billing, audit, event, or usage tables are
  usually the truth; rollups on a parent document are usually convenience.
- **Who else READS it?** If the enforcement/billing path reads a *different*
  source than the one you used, you are not measuring what the system acts on.
- **Does it agree with the ledger?** Spot-check a handful of rows both ways. A
  ratio that is not ~1.0 is the finding.

> **Real case (ENG-1422).** An entire spend audit was built on
> `OrchestrationRun.total_cost_estimate_usd` — it sat right on the run document.
> It is written at `tasks.py:674` as a sum of `step_runs[].cost_estimate_usd`,
> which is itself a *local re-estimate from token counts* (`agent.py:596`
> `_estimate_cost`), not billed cost. Real spend came from joining
> `step_runs[].session_id` → `APIUsage`. The field under-reported by **2.82×**,
> and non-uniformly (2.52× on one spec, 6.34× on another), so it could not even be
> corrected with a constant. Every figure in the audit was a third of the truth.

---

## 2) The window — does the period straddle a change?

A measurement window that spans a deploy describes two different systems averaged
together, and the average describes neither.

- `git log <remote>/<prod-branch> --since=<start> --until=<end> -- <relevant paths>`
- Check the issue tracker for work **completed** in the window, not just open.
- If anything landed mid-window: **split the data on that boundary and report the
  post-change bucket as the answer.** Show the pre-change bucket as history only.
- Watch for a *second* boundary inside the "clean" half.

> **Real case (ENG-1403).** An audit measured Aug 7–19. Five cost fixes shipped
> inside it (Aug 8–13). Re-derived on the post-fix window: org spend $77.05 →
> $26.95, "48% of spend" → 10.9%, and two tickets had been filed against problems
> that were already fixed. A second boundary (Aug 18) was hiding in the clean half
> and changed a separate conclusion.

---

## 3) The proxy — does the thing counted mean what you think?

Every metric is a proxy for the thing you actually care about. Name the gap.

- What does this field/marker **literally assert**? Write it out.
- What do you **want** it to mean? Where do those diverge?
- What would the data look like if the real thing were absent but the proxy still
  fired — and can you tell those apart?
- Is there a repair/cleanup/backfill step nearby? Its existence is evidence the
  thing it repairs happens often.

> **Real case.** `produces:action_item:*` markers were read as "this run produced
> something useful", and waste was reported at 3%. The marker asserts only that
> **a record was created**. A separate measurement found ~84% of the same runs
> produced nothing of value to the user — and the spec ran a step literally named
> `repair_empty_compound` on every run, which was the visible clue that records
> were routinely landing empty.

---

## 4) The join — does absence mean absence?

When a conclusion rests on rows *not* being found, the linking field is the
suspect, not the data.

- Is the join key **always populated** on the rows you expect to find?
- Run a **positive control**: take a case you know produced output and confirm the
  join finds it. If it does not, the join is broken, not the world.
- Prefer an in-record signal over a cross-collection join wherever one exists.

> **Real case (ENG-1410).** "Which runs produced nothing?" was answered by joining
> on `source_orchestration_run_id`. Two specs appeared 100% barren. That field is
> never stamped on the rows they write — their agents were calling the write tool
> in 126/150 and 146/150 sessions. The join overstated waste by **~70×**.

---

## 5) The population and the sample

- **How many rows?** A rate from a handful of runs is an anecdote.
- **How long?** Two days of one user is not a weekly rate — say so if extrapolating.
- **Is the population the one in the claim?** An org total is not one person's usage.
- **What is excluded, and does the exclusion change the answer?**

---

## 6) Has someone already measured this?

Before publishing, search the tracker for the symptom **in the user's words**, not
your mechanism. Check Done/Staging/In Progress, not just open. A merged fix from
this morning still makes a new finding a duplicate.

---

## 7) Run the interrogation in a fresh sub-agent

**Do not self-review.** The context that produced the claim is exactly the context
that will defend it. Dispatch a sub-agent that receives:

- the one-sentence claim and its numbers
- the field names, queries, window, and population used
- **none of the reasoning** that produced it

and is instructed: *"Assume this claim is false. Identify the most likely reason.
Check the instrument, the window, the proxy, the join, and the sample in that
order. Report what you would need to see to believe it."*

Then reconcile. A critic finding nothing is a real result — record what it checked.

---

## 8) Report

State plainly, in this order:

1. **Verdict** — stands / stands with caveats / does not survive
2. **What was checked** and what was found, per section above
3. **The corrected claim**, if it changed — with the old figure named, so anyone
   who saw the first version knows to update
4. **Residual risk** — what is still unverified, and what would settle it

Publish the caveats *with* the claim, not after someone asks. A finding whose
weaknesses are stated by its author is trusted; one whose weaknesses are found by
a reviewer is not.

---

## The one-line version

**Before any number becomes a decision: where did it come from, what shipped
during it, and does it mean what I think it means?**

---

## Headless mode (`--headless`)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape,
the local queue contract, the ask→fallback rule, the Linear footprint are
defined once there. This section states only what applies when this skill
runs as a sub-agent under a headless caller.

**You are never dispatched as a headless act.** You run as a sub-agent inside
one (today: `piv-investigate-issue`'s step 7, and `implement-issue`'s step 7b
for red-team). You write **no** `status.json` and **no** queue entry — you
return your report to the caller, which owns both.

**Never ask.** There is nobody to ask. Where the rubric would ask for data,
take the documented default: **report the gap as a finding**.

**Data access is usually restricted.** The `dontAsk` profile is path-scoped
and allows no database read tools and no piped commands. So: §1's ledger
spot-check and §4's positive control will frequently be unobtainable. When
they are, say **"could not obtain the rows"** and treat that as the finding —
never reason around the missing replay and never present an un-run replay as
a passed one. This is the same rule `implement-issue/SKILL.md:388-390`
already applies to red-team's replay.

**Never write to the repo, never push, never post to Linear or a PR.** Your
output is prose returned to the caller; the caller decides where it lands
(for the bug path: the RCA's `## Adversarial review` section).

**Verdict wording is load-bearing** — the caller branches on it mechanically.
Use exactly §8's own vocabulary: `stands` / `stands with caveats` / `does not
survive`. A near-miss phrasing is unroutable.

**A critic finding nothing is a real result** — §7 already says this. Record
what was checked. Do not manufacture a finding to look useful.
