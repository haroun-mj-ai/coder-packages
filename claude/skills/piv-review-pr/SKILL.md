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

**Requires the `review-main` (claude, high effort) / `review-debate` (codex, model `gpt-5.6-sol`, effort `max` —
this project's default for every Codex lane) delegate-skills lanes** — already configured globally
(`delegate-setup`). If they're ever missing, `debate-review` says so plainly; don't improvise a substitute
pairing, and don't point these lanes at anything else this project uses them for (e.g. the separate `plan-debate`
lane, which challenges plans rather than code).

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

## Headless mode (--headless)

Read `.claude/skills/headless-protocol.md` first — the `status.json` shape, the local queue contract, the ask→fallback rule, the Linear footprint are defined once there. This section states only what this skill's own ask points map to.

**Phase**: `review`. `phase_at_question: "review"`. Invoked as `/piv-review-pr <pr-url> --headless --issue ENG-<id> --run-dir <d> --ports fe=..,be=..`. **`--issue` is a headless-only token** and is required: this skill's own arguments carry a PR, not a ticket, and every queue write needs the ENG id. It is the only new flag this feature introduces on any skill.

**Preflight, before anything else** — fail fast rather than mid-round: `command -v gh` + `gh auth status`, `command -v jq` (a **hard** dependency of `babysit-pr/scripts/threads.sh`, declared at `babysit-pr/SKILL.md:5`), `command -v node` (required by `debate-review/scripts/review-pr.mjs`). Any missing → `FAILED`, `detail` naming the missing tool. A cron-launched act's `PATH` inheritance is not guaranteed even though all three resolve for an interactive shell here.

**Work in the ticket's worktree**: resolve it via `git worktree list | grep "wt-eng<id>-"`, `cd` there before `gh pr checkout`. `threads.sh` picks the forge from the cwd's git origin (`:22-25` above), so the cwd is load-bearing, not incidental.

**State guard** (`:32` above): `MERGED`/`CLOSED` → **`DONE`**, `detail: "PR already <state>; nothing to review"`, and swap the ticket to `ready-to-test` — a merged PR is not a failure. `DRAFT` → proceed. An already-reviewed head sha (`debate-review` exit code 3, `:62` above) → do **not** `--force`; proceed straight to the `babysit-pr` rounds using the existing review.

**Phase 3 validation** (`:44-46` above) with `--ports`: bind exactly the two given ports if the suite needs a server; teardown before any terminal write.

**`babysit-pr` under headless** — the mapping table, this section's real payload:

| `babysit-pr` behavior | headless resolution |
|---|---|
| Blockers (`:132-146`) | unchanged and fully autonomous: verify, reproduce where practical, fix, run the gate, one consolidated push per round, reply in-thread, resolve. Already needs no human. |
| Reviewer silence / rate-limit (`:265-268`) | unchanged: mark the reviewer unavailable, do not wait out a cooldown, disclose the gap. Never report an unreviewed head as clean. |
| **Non-blockers: one batched ask per round (`:222-238`)** — the one genuine design call | **auto-apply the skill's own stated recommendation per item**, with one carve-out. "fix now" → apply it in the round's consolidated push. "open an issue" → file it (allowed via `mcp__github__issue_write`) and reply with the link. "reject" → reply with the evidence and resolve. **Carve-out:** a "fix now" whose change would touch a file **outside this PR's diff** is *not* auto-applied — record it as a deferred note instead. Reasoning: (a) the recommendation is authored by the same verification pass that classified the finding non-blocking, so applying it is the protocol's *documented default* branch, not an invention; (b) a non-blocker by definition ships nothing broken, and every applied change is visible in the diff the human reads before merging — a bounded, reviewable failure mode; (c) parking the whole act on a nitpick would spend the pipeline's scarcest resource (the owner's attention) on its cheapest findings, exactly inverted; and (d) the carve-out is what keeps it safe — out-of-diff edits are scope creep past the fix's blast radius, which is precisely what the batched ask was really protecting against. Every auto-applied item and every deferral is recorded in the ticket's `history` and in `detail`, so the choice is reversible. |
| Budget boundary — 2 repair pushes + 2 re-review cycles (`:240-243`, `:279-280`) | **`NEEDS_HUMAN`**. The hand-off payload maps directly: `question` = remaining findings + unresolved thread count + last-reviewed sha + unavailable reviewers. Never describe an unreviewed head as clean. |
| Every "stop and speak up" item (`:310-322`) | **`NEEDS_HUMAN`**, one per trigger, no invention needed: an out-of-scope-demanding finding; two bots unresolvably contradicting; a finding recurring after one re-verified retry; **any human reviewer comment, always**; CI failing for infrastructure reasons; budget exhausted. |
| "Ask the user whether to merge" (`:305-308`) | **the terminal, permanently.** Never simulate, never merge, never approve. Under headless: stop here and write the success end state below. |
| Attribution (`:190-198`) | unchanged: `gh api user -q '.name // .login'` once per session, and sign the model name. |
| Harvest-count discipline (`:66-76`) | unchanged and important: print the unfiltered totals before any filter; a filter eliminating 100% of items is presumed broken. |
| **Branch pushed to by someone other than this act, mid-round** (gap identified by Codex's independent second draft, Phase 5c) | `NEEDS_HUMAN`. Before each repair push, check the branch's remote head against the SHA this act last pushed; a mismatch means a human (or another process) pushed to it. Never treat that push as, count it against, or silently rebase over — the repair-push budget and the round loop both assume every push during review originates from this act, and that assumption breaks the moment a human is also touching the branch. |

**Success end state**: rounds worked to the budget or to a clean merge-gate round, nothing unresolved that this act can close. One write:

```bash
python3 "$QUEUE_PY" --ap-home "$AP_HOME" set <ENG-ID> --state ready-to-test \
  --field pr_urls='["<url>", ...]' \
  --event "review rounds worked, awaiting your merge decision"
```

Linear: add label `agent:ready-to-test`; state stays `In Progress`; **never** `Staging` or `Done`; never a comment. Then `status.json` with `status: DONE`, `phase: "review"`, `pr_urls` filled, `detail` = rounds run + blockers fixed with SHAs + findings rejected + issues filed + unresolved-thread count + CI state. Leave the kata ref **open** at `work.attention ok` — this phase never merges, so it never performs post-merge closeout. Without this write the ticket never leaves `piv-reviewing`.

**This is where the new pipeline rejoins `ap`'s never-merges invariant** — said explicitly, and why it is structural rather than a policy: `piv-review-pr:17-19` and `babysit-pr:305-306` both refuse on their own terms, and `mcp__github__merge_pull_request` is on the profile's **deny** list.

**`debate-review` backgrounding.** `:60-62` above says to background it — under headless, backgrounding across a turn boundary is fatal (the protocol's background rule). Run it as a **blocking foreground** command; if it cannot finish in-turn, write an interim `FAILED` first.

**`babysit-pr` pushes repair commits.** Same `haroun/*` push-permission constraint as `piv-create-pr`; `git push --force-with-lease` is allowed, raw `--force` is denied.

**Implementation-report lookup, kind-branched.** `:36-42` above's "implementation report at `.claude/reports/*{branch}*`" lookup points at a **`kind`-branched** path, so the documented-deviation cross-check actually finds something for either fork:

| ticket kind | implementation report to cross-check |
|---|---|
| bug | `docs/issues/reports/<ENG-ID>-fix-report.md` |
| feature | `docs/plans/reports/<ENG-ID>-<slug>-report.md` |

Everything else in this section — the phase, the required `--issue` token, the preflight, the worktree resolution, the state guard, the `--ports` rule, the entire `babysit-pr` mapping table including the non-blocker auto-apply carve-out and the human-pushed-branch stop, the success end state, and the never-merges statement — is verified already kind-agnostic; no change needed.
