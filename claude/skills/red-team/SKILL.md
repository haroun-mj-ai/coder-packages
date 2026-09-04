---
name: red-team
description: Attack a proposed solution, fix, plan, or design BEFORE it is built — enumerate what the guard being changed was catching, what the change wrongly permits, whether the discriminator survives an adversary, what the blast radius is, and whether the thing is even needed. Replays the proposal against real historical data rather than reasoning about its reach. Runs the attack in a fresh sub-agent that never sees the argument for the proposal, so it cannot be persuaded by it. Use before implementing a fix, before approving a plan, and especially when relaxing a validation, verifier, gate, or cap. Do NOT use to review code already written (that is /code-review) or to check whether a claim is true (that is /challenge).
---

# red-team

Most bad fixes are not wrong about the problem. They are **under-specified about
the boundary** — they let through things the original guard existed to catch, or
they build something the system already does.

This skill asks the five questions that separate a fix from a regression.

**Not this skill's job:** reviewing written code (`/code-review`), validating a
claim or dataset (`/challenge`), or deciding whether the work is worth doing.

---

## 0) State the proposal as a behaviour change

One sentence: **"After this change, X will happen where Y happened before."**

Then name, explicitly:
- the **guard, gate, verifier, validator or default** being changed
- the **cases** that currently take the old path
- what the change is **not** touching

If the proposal cannot be stated as a behaviour delta, it is not ready to attack —
or to build.

---

## 1) What was this guard catching?

**The first question, and the one most often skipped.** A guard that rejects
something it shouldn't is still, usually, catching several things it should.

- Enumerate every failure mode the guard currently blocks. Read its code, its
  docstring, its tests, and the ticket that introduced it.
- For each: **does the proposed relaxation also let it through?**
- Which of them **must stay fatal**, and why? A cause that a downstream layer will
  reject anyway is not unblockable — relaxing it moves the failure later and hides
  it, which is worse than failing now.
- Is there an existing sanctioned exit already in the code? Mirror its shape
  rather than inventing a parallel one.

> **Real case (ENG-1401 / PR #736).** A verifier accepted two endings while the
> prompt sanctioned three, so correct runs were recorded as failures. The obvious
> fix — sanction the third ending — would also have swallowed two *structurally
> broken* cases (`UPDATE_TARGET_AMBIGUOUS`, `ROLE_CREATE_MISSING_PARENT`) that no
> human answer can unblock, because the payload validator rejects them regardless.
> The shipped fix kept those two fatal. The obvious fix would have turned real
> breakage green.

---

## 2) Is the discriminator adversarial?

The change distinguishes a good case from a bad one. **Assume something is trying
to produce the good signal without doing the good thing.**

- What exactly must be true for the new path to be taken?
- Can a **failing** or **hallucinating** actor also make that true?
- Is the signal visible to the party who benefits from it, or only internally?
- Prefer signals that require the actual work to have happened over signals that
  merely claim it did.

> **Real case.** The sanction was gated on a rep-**visible** `description` field —
> never `agent_brief`, which the same prompt calls backend-only. "A question the
> rep cannot see earns nothing." An agent that did reads only and then asserted
> *"I filled the task"* still fails, and both directions were tested.

---

## 3) Replay it over real history

**Do not reason about the change's reach. Compute it.**

- Pull every historical row the change would have touched.
- Reconstruct what the new predicate would have decided for each.
- Report the split — and inspect the cases that come out *differently* than
  expected, individually.
- A discriminator that reclassifies 100% of cases is not discriminating; one that
  reclassifies 0% is not doing anything.

> **Real case.** Replaying 30 historical failures: **29 → succeeded, 1 still
> fails**. The one that still failed had called the write tool zero times — exactly
> the hallucination case the guard exists for. That single number proved the
> discriminator did real work on real rows.

---

## 4) Blast radius

- What else uses the machinery being changed? Enumerate call sites, not guesses.
- Is the change **downgrade-only** or can it harden a verdict too? A change that
  can only ever soften has a bounded failure mode; one that can do both needs
  twice the proof.
- What reads the field/behaviour downstream — dashboards, enforcement, exports,
  customer-facing surfaces?
- What will visibly change for a user or an operator the moment this ships, and
  does anyone need warning?

> **Real case.** *"Blast radius of the machinery change is exactly one step —
> `crm_update_drafter` is the only spec in the repo with `verify_fatal=True`."*
> That sentence is the deliverable, and it took one grep.

---

## 5) Does the system already do this?

**Check the end-user surface before building one.** The cheapest fix is the one
already shipped.

- Open the actual UI/API/output path the proposal targets. What does it do today?
- Is there a state or branch that already handles this, unexercised because
  upstream never produced it?
- Would fixing the upstream signal make the downstream work with no change at all?

> **Real case.** A plan committed frontend code to "surface the question to the
> rep". The merged fix shipped **no frontend change** — a succeeded run already
> derived the right state and the panel already rendered the question un-clamped.
> The entire UI unit was waste, and it was the *expensive* half of the plan.

---

## 6) Would a test catch the regression?

- For each failure mode from §1 that must stay fatal: **is there a test that fails
  if it stops being fatal?**
- Mutate the fix deliberately — break the discriminator — and confirm the test
  that should catch it does, **by name**, not just "something failed".
- Check fixtures actually exercise the branch: a guard tested with values that a
  simpler check already separates is a vacuous test.

> **Real case.** 16 hand-mutants, 16 killed — and one round exposed a **vacuous
> test of the author's own**: the both-falsy guard's fixture used `None` vs `""`,
> which plain inequality already rejects, so the guard was never exercised.

---

## 7) Run the attack in a fresh sub-agent

**Do not red-team your own proposal in the context that produced it.** Dispatch a
sub-agent that receives:

- the behaviour delta from §0
- the guard's current code and tests
- **none of the argument for why the change is right**

instructed: *"This change is about to ship. Find the case where it causes harm.
Start from what the guard was catching. Then find the input that produces the new
path without doing the work. Report the single most likely regression."*

---

## 8) Report

1. **Verdict** — ship / ship with the named additions / do not ship as specified
2. **Must-stay-fatal list** from §1, with how each is preserved
3. **Replay result** from §3, with the anomalies inspected
4. **Blast radius** from §4, enumerated not estimated
5. **What the proposal can drop** — the parts §5 showed were unnecessary
6. **The tests** that hold each boundary

---

## The one-line version

**Before building a fix: what was the old behaviour catching, what does the new
one let through, and what would it have decided for every case that already
happened?**

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
and allows no database read tools and no piped commands. So: §3's replay over
real history will frequently be unobtainable. When it is, say **"could not
obtain the rows"** and treat that as the finding — never reason around the
missing replay and never present an un-run replay as a passed one. This is
the same rule `implement-issue/SKILL.md:388-390` already applies to this
skill's replay.

**Never write to the repo, never push, never post to Linear or a PR.** Your
output is prose returned to the caller; the caller decides where it lands
(for the bug path: the RCA's `## Adversarial review` section).

**Verdict wording is load-bearing** — the caller branches on it mechanically.
Use exactly §8's own vocabulary: `ship` / `ship with the named additions` /
`do not ship as specified`. A near-miss phrasing is unroutable.

**A critic finding nothing is a real result** — §8 already says this. Record
what was checked. Do not manufacture a finding to look useful.
