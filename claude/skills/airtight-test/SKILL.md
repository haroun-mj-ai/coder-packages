---
name: airtight-test
description: Verify a claim about how something actually behaves — a vendor's pricing/feature-gating claim, an AI support agent's answer, an assumption about your own backend code — by building a real scenario that could have come out either way and watching what actually happens, instead of reasoning from documentation or settings pages. Use before recommending a third-party tool/service to the team, or to verify your own backend-only change end to end when there's no UI to click through. Do NOT use to review code for bugs (code-review), attack a proposed design (red-team), or judge whether a data/metrics claim is true (challenge) — this skill is about observed behavior, not code quality or numbers.
context: fork
---

> **Runs forked (`context: fork`).** This skill runs as a separate agent so screenshots and page dumps stay out of the caller's context. You can't ask the user anything mid-run. Wherever this file says to ask the user, stop and return the question as your result, together with what you've verified so far.

# airtight-test

A claim about behavior is not verified because it sounds right, or because a
settings page says so, or because an AI agent answered confidently. It is
verified because you built a scenario that could have failed, ran it for
real, and watched what happened. This skill is that discipline, generalized
from a real case: evaluating Trunk.io's merge queue before proposing it to
the team, where the pricing page, the live product, and Trunk's own AI
support agent gave three different answers about what the free tier
actually includes — and only running the real thing settled it.

## When to reach for this

- Evaluating a third-party tool/service before recommending it: does the
  feature actually work the way the marketing/docs say, what's the real
  cost/gating model, do the integrations actually fire.
- Verifying your own backend-only change end to end when there's no UI to
  click through — pairs with `/browser-verify` or `/test-issue` for
  anything with a UI, this is the no-UI equivalent.

## Not this skill's job

- Finding bugs in code you're reading (`/code-review`).
- Attacking a proposed design before it's built (`/red-team`).
- Deciding whether a number/metric/dataset is trustworthy (`/challenge`) —
  that skill interrogates data; this one interrogates live behavior.

## The core discipline

### 1. Pin the actual claim down, not the general topic

Not "test Trunk's merge queue" — "confirm a PR that genuinely conflicts with
another gets removed from the queue without blocking the others, and that
this is a real kick-out, not just a PR that never got in." Write it as one
falsifiable sentence before doing anything. If you can't state it that
precisely, you don't know what you're testing yet.

### 2. Test the actual value proposition, not just the mechanics

Ask: "what's the one thing someone would be relying on if this doesn't work
as advertised?" Design the scenario that can only pass if *that specific
thing* is true — not a nearby, easier-to-trigger thing that looks similar.

> **Real case.** A first attempt submitted a PR with an already-failing
> required check. It never entered the queue at all — that's GitHub's own
> branch-protection gate rejecting it before the queue is even involved, not
> the queue's kick-out mechanism. It *looked* like a successful test but
> proved nothing about the actual claim. The real test needed two PRs that
> each pass completely on their own but conflict only when combined (one
> renames a function, the other calls it) — the classic "two green PRs break
> main together" case merge queues exist to catch. Only that scenario could
> distinguish "works as claimed" from "never got the chance to fail."

### 3. Build a scenario you control the outcome of

If you can't deterministically make the thing pass **and** fail on demand,
you can't tell "working" from "coincidentally fine so far" apart.

> **Real case.** A GitHub Actions workflow read two marker files committed
> alongside the change under test: `CI_DELAY_SECONDS` (sleep this long) and
> `CI_SHOULD_FAIL` (exit 1 if present). This turned "wait and see" into "make
> it fail exactly when I want, and confirm the system reacts correctly" —
> without touching any real application code.

### 4. Cross-check every claim against independent sources, don't average them

When sources disagree, find the authoritative one — don't split the
difference or take the most recent answer as final.

> **Real case.** Trunk's pricing page showed Merge Queue as unavailable on
> Free tier. The actual product ran it fully on a Free-tier account with
> zero gating. Trunk's AI support agent, asked once, guessed wrong ("Merge
> Queue is unlimited on free tier, billing kicks in over 5 committers" —
> close, but not sourced). Asked again with shell access to the real docs,
> it quoted the licensing page directly: "all features are available
> regardless of licensing status; you do not unlock additional features by
> purchasing a license." That direct quote from the primary source is what
> settled it — not the first three answers, and not a vote between them.

### 5. Verify side effects at the actual destination

"Settings say Connected" is not evidence a message was sent. The message
showing up in the real channel, with the right content, at the right time,
is.

> **Real case.** A Slack integration's settings page said the channel was
> connected. Confirming it required watching the actual Slack channel and
> seeing real messages land for each real pipeline event (submitted →
> waiting → testing → failed), with correct per-event content — not just
> trusting the "Connected" badge.

### 6. Evidence over impression

Exact quotes, screenshots saved to disk (not just glanced at), HTTP status
codes, exact timestamps, exact settings-page text. A paraphrase of what a
page "seemed to say" doesn't survive someone else asking "are you sure."

### 7. Don't assume stuck means broken — but reach a real resolution

Some real state transitions are just slow, not failed. Poll with patience
(background polling, not repeated impatient re-checks) before concluding a
scenario failed. But don't leave it ambiguous either — get to a definitive
pass/fail, even if it takes several minutes of watching.

> **Real case.** A PR that had already passed its retest sat "Pending" for
> ~6 minutes before actually merging — not stuck, just waiting out a batch
> timer with no partner PR to pair with. Concluding "broken" at minute 2
> would have been wrong; so would giving up watching without ever finding
> out it eventually succeeded.

### 8. Report a verdict per claim, plus what's not covered

State PASS / FAIL / UNCLEAR against each specific claim you pinned down in
step 1 — not a vague overall impression. Name what you did **not** exercise
and why, every time, even when everything you did test passed. A report
with no gaps listed hasn't actually checked whether there are any.

## For third-party tool evaluation specifically

- Use a real, disposable test surface — a throwaway personal repo, not the
  team's actual repos — so failed experiments cost nothing and nothing
  leaks into shared history. Clean up after: close throwaway PRs, delete
  throwaway branches, leave a comment explaining what superseded what so a
  future reader isn't confused by dead experiments.
- Before relying on any free-tier/trial behavior, check the vendor's own
  live billing/plan page directly (not the marketing pricing page) — and
  look for how they describe *enforcement*, not just what's "included."
  Hard technical gate and soft/compliance-based licensing look identical
  from the pricing page but behave completely differently in practice.

## For your own backend-only changes (no UI)

- Don't stop at unit tests. Design a real seed → trigger → verify scenario:
  seed the actual data shape the code path expects, trigger it the way
  production would (a real API call, worker job, or webhook — not calling
  the function directly), and verify via direct DB/API state, not "it
  didn't throw."
- If the change touches an external integration, exercise the real sandbox
  integration rather than mocking it, wherever that's available at zero
  cost/risk.

## Permission boundary

**Confirm with the user first, every time:** creating any real external
account, connecting a real Slack channel/workspace, installing a GitHub
App, generating an API token, or starting any trial or billing-relevant
action.

**No need to ask, proceed freely:** creating and deleting your own
throwaway branches, PRs, or repos that you fully control and can clean up
yourself; local seed scripts, marker-file tricks, and test workflows that
never leave the disposable test surface.

## Reporting

Report findings in chat as you go. At the end, **always publish an Artifact**
that leaves no doubt about what was and wasn't verified — this is the
deliverable, not an optional add-on, and it stands on its own even if the
chat scrolls away or gets summarized. This is a deliberate exception to the
general "don't build an artifact unless asked" default: a claim this skill
exists to verify is exactly the kind of thing a reader will later ask "are
you sure?" about, and the artifact is the answer.

The artifact must include, for every claim pinned down in step 1:

- The exact scenario built (seed data, accounts, marker files, whatever made
  the outcome controllable) — specific enough that someone else could
  reproduce it.
- Every real request/response, command, or state check that produced
  evidence — exact status codes, exact response bodies or field values,
  exact log lines, exact timestamps. Not a paraphrase.
- **Screenshots, embedded inline, whenever the claim touches anything a
  human would look at** — a UI, a settings page, a dashboard, a chat
  message landing in a real channel. A claim that never touches a UI (a
  pure API/backend verification) doesn't need screenshots to be complete,
  but a claim that does is not fully verified without one. Save every
  screenshot to disk as it's taken (never just glance at a preview) and
  bring each one into the artifact — don't describe a screenshot in prose
  when the image itself is the evidence.
- Bugs or false claims found ALONG THE WAY that are not the claim under
  test — a seed-data mistake is not a finding, but a real discrepancy in
  the system under test is, even if the original claim being verified
  still turns out to hold. Say which is which.
- The PASS / FAIL / UNCLEAR verdict per claim (step 8), plus what was not
  exercised and why.
- What was cleaned up afterward (throwaway accounts, seed data, branches)
  so a reader knows nothing was left behind.

Don't auto-file a ticket from this — if the user wants a written proposal
or a filed issue out of the findings, that's a separate, explicit ask. The
artifact is the verification record; a ticket is a different document with
a different audience.
