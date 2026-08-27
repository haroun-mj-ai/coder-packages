---
name: piv-review-pr
description: Full pull-request review — two models argue before anything is posted (debate-review), then the PR gets its rounds worked to resolution (babysit-pr). The agentic gate that runs on an open PR before a human merges. Use after piv-create-pr.
argument-hint: "<pr-number | pr-url | branch>"
---

# Review PR: The Agentic Gate Before the Human

**Input**: $ARGUMENTS

This skill no longer runs its own single-model review — it drives **`debate-review`**: a main reviewer (Claude)
finds issues, a debate reviewer (Codex) tries to knock each one down or add a real gap the first missed, and the
main reviewer makes the final call before anything posts. That's a better-fit use of Codex than a same-tier
second opinion or a symmetric "both review, average the verdicts" setup — cross-model review research
(arXiv:2607.21656) found Codex *reviewing* Claude-authored code in isolation makes it worse (91.4%→82.8%), but
`debate-review`'s role for Codex isn't "produce an independent verdict," it's "try to refute a specific claim a
stronger reviewer already made" — a narrower, adversarial-verification task, with Claude holding the final call.
It never approves and never requests changes — matches this project's own convention that nothing in this chain
merges or approves autonomously; a human always makes that call.

## Phase 1 — Resolve the PR and check out the code

Resolve the input to a PR number (a number, a URL, or a branch via
`gh pr list --head <branch> --json number -q '.[0].number'`), and check it out locally — `debate-review` resolves
and diffs the PR itself, but Phase 3 below still needs the code on disk to actually run the gates:

```bash
gh pr view {N} --json number,title,body,author,headRefName,baseRefName,state,additions,deletions,changedFiles,files
gh pr checkout {N}
```

State guard: `MERGED`/`CLOSED` → stop ("nothing to review"); `DRAFT` → proceed, `debate-review` handles it fine.

## Phase 2 — Load context, for cross-checking afterward (not fed into the debate)

- **The implementation report** (if `piv-implement` wrote one — `.claude/reports/*{branch}*`) + its plan: note the
  **documented deviations**. `debate-review` has no way to know these are intentional — it's a generic,
  project-agnostic tool — so after it posts (Phase 4), cross-check any finding against this list and flag to the
  human when a "finding" is actually a known, documented deviation, so nobody spends a round on it.
- **`CLAUDE.md`** + any `.claude/references/` — for your own judgment when reading the result, not something
  `debate-review` reads either.

## Phase 3 — Run validation

Run the project's real suite (the **`piv-validate`** skill, or the plan's validation commands) — tests, type-check,
lint, build. Capture pass/fail + counts. A red suite is a finding in itself, independent of what the debate finds.

## Phase 4 — Run the debate review

**Requires the `review-main` (claude) / `review-debate` (codex) delegate-skills lanes** — already configured
globally for this project (`delegate-setup`, effort `high` on both). If they're ever missing, `debate-review`
says so plainly; don't improvise a substitute pairing, and don't point these lanes at anything else this project
uses them for (e.g. a separate plan-debate lane).

```bash
node "<debate-review skill-dir>/scripts/review-pr.mjs" <pr-url-or-number>
```

**Run this in the background** (`run_in_background: true` in Claude Code) — it's two or three implementer
sessions back to back and takes minutes; don't poll tightly, keep doing Phase 2/3 work while it runs. Exit code
`3` means this exact head sha was already reviewed — don't re-run without `--force`.

What comes back: one posted review (or printed, for `--local`/`--dry-run`) with findings marked `agreed` (both
models stand behind it) or `contested` (Codex tried to refute it, Claude held the finding — both sides' reasoning
shown). A `contested` finding is not weaker evidence than an `agreed` one — it's a claim with a known
counterargument already weighed, which is worth more scrutiny from the human, not less.

## Output + hand off

Print: the review URL, the agreed/contested counts, Phase 3's validation results, and any documented-deviation
cross-check from Phase 2. Then hand off:

**"Posted on the PR by debate-review. Next: `babysit-pr` to work the rounds — verify each finding against the
code, fix the blockers, reply in-thread, resolve, and re-trigger the next round — until the PR meets its merge
gate. A human decides when to actually merge; nothing in this chain does it for them."**

## Notes

- **This replaced a single-model `Agent(model: "opus")` dispatch** that this skill used to run directly. The
  debate structure is a strict upgrade for the same reason the opus-only version existed — genuine independence
  from the code's own author-context — plus it gets Codex's input in the direction that actually helps instead of
  the direction the research shows hurts, and posts properly attributed inline comments instead of an internal
  report you have to go read yourself.
- **`piv-fix-review-findings`** still exists for a non-PR review (e.g. `piv-review-changes`'s local, pre-commit
  pass). For anything posted on a PR by `debate-review` — or by Codex's own GitHub app, or Greptile, or any other
  bot — use **`babysit-pr`** instead; it harvests every reviewer's threads in one pass (not just this skill's own),
  which a PR usually accumulates more than one of.
