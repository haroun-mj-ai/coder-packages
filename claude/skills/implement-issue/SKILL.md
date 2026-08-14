---
name: implement-issue
description: Take a Linear task ID (or a free-text description, filing the ticket first) from ticket to an open PR in two phases separated by a hard approval gate. Phase plan: fetches every repo into fresh worktrees, classifies risk (Light/Standard/Heavy), drafts acceptance scenarios from the raw ticket in a fresh sub-agent context, drafts the plan via an Opus sub-agent, adversarially audits it with an independent fable-model sub-agent, commits the plan, and stops for approval. Phase implement: reuses that worktree (with a staleness check before touching anything), dispatches model-matched implementer sub-agents per work unit, runs a spec-vs-test audit plus a fresh-context code review with zero plan visibility, runs the real quality gates, derives the change's blast radius, QAs it in the browser, writes the durable QA artifact under docs/plans/qa/, commits, runs roborev, then gates on scope/secrets, rebases onto fresh dev, pushes, and opens the PR(s) — no server or Docker required, this is pure git/GitHub-API reusing gates already run. Ends by recommending /ship-work to confirm the push is rebased and locally gate-clean; never merges, and never waits on CI itself (neither skill does — CI-watching and merging are a human's later, separate call). Headlessly takes --phase plan or --phase implement so autopilot can run the two phases hours apart with a human's approval in between; --phase implement now pushes and opens PRs headlessly too. Supersedes /plan-issue and /implement-plan as the single main path. Use when the user says "implement ENG-123", hands you a Linear id or free-text description to take from ticket to an open PR, or on /implement-issue. Do NOT use to merge — nothing in this chain merges autonomously.
---

# implement-issue

Two phases, one hard approval gate between them: **plan** produces a
reviewed, committed plan and stops; **implement** builds it, tests it,
pushes it, and opens the PR(s), then hands off to `/ship-work` to confirm
the push is rebased onto the latest `dev` and locally gate-clean.
Interactively these flow in one session (`ExitPlanMode`'s approval leads
straight into implementation). Headlessly they are two separate invocations,
`--phase plan` and `--phase implement`, because a `claude -p` process cannot
synchronously block for hours waiting on a human's `go` comment — see
Headless mode below.

This skill supersedes `/plan-issue` and `/implement-plan`, which are now
retired stubs pointing here. It pushes and opens the PR(s) once the change is
built, tested, and reviewed — but it never merges, and neither does
`/ship-work`. Watching remote CI and merging are always a human's own,
separate action, on their own timeline.

## Usage

```
/implement-issue ENG-123
/implement-issue the pipeline board loses column order after a CRM sync
/implement-issue --phase plan ENG-123 --headless
/implement-issue --phase implement docs/plans/2026-08-14-eng-123-foo.md --headless --ports fe=5174,be=8001
/implement-issue --no-issue <description>       # plan without creating a ticket
/implement-issue --no-claim ENG-123              # skip the Linear assignee/status write
```

With no `--phase` flag, the skill runs interactively end to end through the
approval gate. Given a Linear id or URL, it reads that issue. Given free
text, it creates the Linear issue first, so the ticket, the plan file name,
the branch, and the commit all share one id.

## Why this shape

Expensive inference belongs at the front, on design; cheap inference does
the reading and the building. Two rules are not negotiable:

- **You (the main session) do the judging. Subagents do the reading.** Do
  not read your way through the codebase yourself, and do not ask a subagent
  what the design should be.
- **Cheap means a pinned agent definition, not an inline model override.**
  The Agent tool accepts `model` but not `effort`, so `Agent(model:
  "sonnet")` inherits this session's effort and costs far more than it looks
  like. Ordinary work dispatches by `subagent_type`: `explorer` and
  `plan-critic` (sonnet, medium), `scout` (haiku, low), `implementer`
  (sonnet, medium). This skill is the **one deliberate exception** to "never
  spawn an opus or fable subagent from a skill" — three specific dispatches
  below (the plan drafter, the plan auditor, the code reviewer) are raw
  `Agent(model: "opus"|"fable", ...)` calls, on purpose, because the whole
  point of each is a different reasoning tier or a genuinely independent
  model family from whatever drafted the thing it's checking. Every other
  unit of work still goes through a pinned `subagent_type`.

  Agent definitions live in `.claude/agents/` in this repo, loaded at
  session start; if a dispatch fails with "agent type not found" after a
  fresh pull, the session predates the file — say so and ask for a restart
  rather than falling back to an inline override.

**Risk tier scales ceremony, never removes it.** Every ticket gets a plan,
an independent plan audit, a fresh-context code review, and real tests. Tier
(classified in Phase A step 2) only scales *how much*: exploration fan-out,
audit effort, verification depth. The hard approval gate, the plan audit,
the code review, and real tests are never skipped for any tier — if you're
ever tempted to skip one for a "trivial" ticket, that's a sign the tier was
misjudged, not a sign the step is optional.

Budget discipline: at most 3 explorers, one exploration round, one plan
audit, one code review — and for Light, no worktree/explorer fan-out at all
(see Phase A step 3).

## Instructions — Phase A: Understand & Plan

### 0. Fetch every repo, and report the drift

Do this before anything else. The main checkout sits on whatever feature
branch was last worked and is routinely 70+ commits behind `origin/dev`; an
explorer reading that tree returns evidence wrong by tens of lines.

```bash
for r in . backend frontend assistants observability; do
  git -C "$r" fetch origin --quiet
done
for r in . backend frontend; do
  printf "%-10s " "$r"
  git -C "$r" rev-list --left-right --count origin/dev...HEAD
done
```

Report the drift — it justifies step 3's worktrees, and if it's zero
everywhere you can say so and skip them.

### 1. Resolve the ticket

**Given an issue id or URL**: `mcp__linear-server__get_issue` for the
description, `mcp__linear-server__list_comments` for the discussion —
requirements are very often only in the comments. Follow what it points at
(`WebFetch` a doc link, `Read` a screenshot, a referenced PDF via the `pages`
parameter). If the issue is thin, say so in the plan's open questions rather
than inventing the requirement.

**Given free text**: create the issue first, before any exploration, so a
mis-scoped ticket gets killed cheaply.

- **Check for an existing ticket first**: `mcp__linear-server__list_issues`
  with `query: "<distinctive keywords>"`. If a plausible match exists, show
  it and ask whether to plan that one instead of creating a duplicate. Also
  scan `docs/plans/` for the same symptom.
- **Do not create a vague ticket.** If the description is too thin to write
  a title and a one-paragraph problem statement without inventing the
  requirement, ask the one question that resolves it.
- Otherwise create with `mcp__linear-server__save_issue` (omit `id` when
  creating — this org's configured Linear MCP server has no `update_issue`
  tool; every write, create or update, goes through `save_issue`):
  - `team: "Engineering"` (id `5e9c24d8-71cc-43ac-bf83-15cc0397f455` if the
    name doesn't resolve)
  - `title`: short and imperative, the change not the symptom.
  - `description`: the user's own words, plus observed/expected behavior if
    stated. State what is wanted, not how it will be built. Mark anything
    inferred as an explicit assumption.
  - `project`: read the live list — `mcp__linear-server__list_projects` with
    `team: "Engineering"`, `fields: ["id", "name", "status"]`. Choose in
    order: (1) the specific feature-area project if one matches, (2) the
    current quarter's catch-all (`status: In Progress`), (3) **Enable LLM
    development** for Claude Code/MCP/docs/tooling, **Meta Project** for
    team/process changes. State which and why in one line; ask only on a
    genuine coin flip.
  - `assignee: "me"`, `state: "Todo"` — flips to `In Progress` once the plan
    exists (step 9).
  - `labels` only when the description clearly says bug or feature; never
    guess. Leave `priority` unset.

  **Report the created id and URL immediately**, before spending anything on
  exploration.

If the Linear MCP is unavailable, say so and continue with `--no-issue`
behavior rather than silently planning against a ticket that doesn't exist.

Then check what already exists: `ls docs/plans/ docs/plans/completed/ 2>/dev/null | grep -i <keyword>`,
and skim `docs/guides/architecture/features/CATALOG.md` for the feature area.

**Suggest a session rename, interactive only** — once the ticket's title is
known, print a `/rename <three words max>` line the human can copy-paste
(e.g. `/rename crm-sync-fix`, `/rename mfa-login-retry`). Pick the three
words from the ticket's title/id, whatever gives the most context in the
least space. **This cannot be done automatically**: `/rename` is a
client-side REPL command Claude Code intercepts from the human's own typed
input before it ever reaches the model — nothing a skill's instructions
cause the agent to output can invoke it, and there is no other API, hook, or
settings key that renames a running session or its terminal tab. Skip this
in headless mode entirely (`claude -p` has no session picker or tab to name).

### 2. Classify the risk tier

Decide out loud, before orienting or exploring, and say which and why in one
line:

- **Light** — a single file, or a small handful in one repo; no new
  endpoint, schema, model field, or migration; no cross-repo touch; no
  architectural decision; you could already write "what changed and why" in
  one paragraph without reading any code. A typo/copy fix, a config or
  constant change, a null-check the ticket already names a `path:line` for,
  a one-line validation tweak, restoring a diagnosed regression.
- **Standard** — everything else you're not unsure about. The default.
- **Heavy** — touches the data model/migrations, auth/security/billing, an
  external-integration credential path, or spans backend+frontend+workers
  together.

When genuinely unsure, default to Standard or higher — never round down to
Light on a guess; a wrongly-skipped audit is more expensive to fix later than
one that found nothing.

This one tier controls four things: exploration fan-out (step 3), the plan
template (step 5), the plan-audit effort (step 7), and Phase B's gate/QA/
audit depth (Phase B, throughout) — never whether the approval gate, the
plan audit, the code review, or real tests run at all.

### 3. Orient and explore

Skipped (beyond a single scout, only if the ticket doesn't already name the
area) for a task tiered **Light** — see the carve-out below.

Dispatch a single `scout` (haiku) first: **which repos are in play, and
where does this area live?** The four repos are separate git checkouts as
siblings: this repo's own root (docs, tests/e2e, scripts — call its
absolute path `<root-repo>` below, resolved with `git -C . rev-parse
--show-toplevel` rather than hardcoded, since it differs per machine),
`backend/`, `frontend/`, `assistants/`. Only root is tracked by this repo's
git.

```bash
for r in . backend frontend assistants; do git -C "$r" status -sb | head -2; done
```

**One worktree per involved repo, cut from fresh `dev`.** Always root (it
holds the plan doc) plus one per repo the scout named. Skip entirely if
step 0 showed zero drift everywhere.

```bash
git -C <repo> worktree list | grep "wt-eng<id>-"   # reuse before creating
git -C <repo> worktree add --no-track \
  <root-repo>/wt-eng<id>-<suffix> \
  -b haroun/eng-<id>-<slug> origin/dev
```

- **`--no-track` is mandatory** — without it the branch's upstream becomes
  `origin/dev` and a bare `git push` later targets `dev` directly.
- Suffix convention: `-root`, `-be`, `-fe`. Base per repo: `dev` for root/
  `backend/`/`frontend/`; `main` for `assistants/`/`observability/` —
  confirm with `git -C <path> branch -a`, never assume.
- If the branch already exists, drop `-b` and add the worktree on it; if
  checked out elsewhere, use that worktree, never force.
- Verify freshness: `git -C <worktree> rev-list --count HEAD..origin/dev`
  must be `0`. Report every path created or reused before exploring.

**Fan out 2-3 explorers, one message, concurrently.** Current state (trace
the code path end to end) / prior art (what should be reused, not rewritten)
/ verification surface (what tests exist, how they run). Every prompt
carries: the absolute worktree path (never the main checkout), a note that
other repos are covered by peers, the ticket's own words, an instruction to
report `path:line` evidence with short quotes, and an explicit demand for
"what does not exist." Cap at 3, one round.

**Light carve-out**: skip the worktree fan-out and the explorer dispatch
entirely. Still do step 0 (free) and this step's scout only if the ticket
doesn't already tell you the area. Write the plan directly in the main
checkout — no worktree needed; Phase B creates one itself if none exists
(its own step 3). If step 3 or step 7 would have been skipped for a task
that turns out to have a real interaction surface once you start writing the
plan, that's a sign it was mis-scoped as Light — say so and go Standard.

### 4. Draft acceptance scenarios via a fresh-context QA sub-agent

Spawn an `Agent` call whose **only** input is the raw ticket text
(description + acceptance criteria + comments from step 1) — not this
step's exploration findings, not any plan draft, not implementation hints.
Have it write concrete, testable scenarios from a real user's perspective:
happy path plus the edge cases the ticket implies.

This is deliberately independent of everything steps 1-3 learned about the
code, so it reflects what the ticket actually asked for rather than what
looks implementable. Carry these scenarios forward as the shared yardstick
for the plan's testing strategy (step 5), Phase B's code review (Phase B
step 7), and the unit/e2e tests (Phase B step 4) — don't let each of those
re-derive its own interpretation of "done."

### 5. Draft the plan via an Opus sub-agent, always

**Regardless of what model the main session is currently running as.**
There is no tool to switch the main loop's own model mid-turn, so the only
reliable way to guarantee Opus-tier reasoning on the plan is
`Agent(subagent_type: "Plan", model: "opus")`, fed the ticket, steps 1-3's
findings, the risk tier, and step 4's acceptance scenarios. The main loop
reviews and presents what the sub-agent produced — it does not draft the
plan itself.

Write it **inside the root worktree** (skip if step 3's Light carve-out
applied — write in the main checkout, and say the plan is untracked), at
`<root-worktree>/docs/plans/YYYY-MM-DD-eng-<id>-<slug>.md` (or
`YYYY-MM-DD-<slug>.md` under `--no-issue`), following `plan-template.md` —
or `plan-template-light.md` for a Light-tiered task.

Non-negotiable parts of the plan (a Light plan's shorter sections already
fold the intent of these in — see `plan-template-light.md`):

- **Evidence.** Every claim about current behavior carries a `path:line`.
- **Work units.** Sized to a single context window per `AGENTS.md` §1 —
  roughly, more than ~15 files read or ~5 touched means split it. Each names
  its repo, files, and own tests; independently executable by an agent that
  hasn't seen this conversation.
- **Tests against the spec, not the implementation.** For each behavior, name
  the test that fails before the change and passes after — seeded from step
  4's acceptance scenarios.
- **The interaction surface.** What else consumes the changed functions,
  components, hooks, endpoints, model fields, query keys, with `path:line`,
  plus tenancy/role/real-time/layout questions.
- **Open questions**, marked `BLOCKING` where Phase B must not proceed while
  unresolved.
- **No `ENG-###` in the code or comments** the plan proposes.

### 6. Ask clarifying questions

`AskUserQuestion` for ambiguous requirements, UX decisions, scope boundaries.
Interactive only — headlessly this maps to the ask→fallback rule below. Do
not assume; fold answers into the plan.

### 7. Audit the plan, then commit it once

Dispatch `Agent(subagent_type: "plan-critic", model: "fable")` — check that
the explicit `model` override actually supersedes `plan-critic.md`'s own
pinned-sonnet frontmatter (the Agent tool's own docs say an explicit `model`
takes precedence); if it doesn't compose for any reason, fall back to a raw
`Agent(model: "fable", effort: <tier>)` call carrying `plan-critic.md`'s
operating rules and exact output schema as prompt text instead of
`subagent_type`. Either way, this is **one** dispatch, not two separate
audits: fable's independent model family (genuinely distinct reasoning from
the Opus drafter in step 5) applying `plan-critic`'s structured rubric —
per-claim `VERIFIED`/`WRONG`/`MISSING` labeling, spot-checking every cited
`path:line`/function/field/lookup key against the real repo, probing every
assumption for whether it's actually verified in code, and an overall
`SOUND` / `SOUND WITH FIXES` / `DO NOT IMPLEMENT` verdict. Effort scales with
tier: **max** for Standard/Heavy, **high** for Light — never skipped
outright, even for a small-looking change.

Fold every finding into the plan, or record an explicit one-line reason it
doesn't apply. Populate the plan's **Design review** section with the
verdict, what changed, and what was rejected and why — keep this honest even
when the audit found nothing; it's the only evidence over time of whether
this step earns its cost. A `DO NOT IMPLEMENT` verdict means rework and
re-audit once, or surface it to the human as a blocking question — never
paper over it.

Then commit: `git -C <root-worktree> add docs/plans/<plan>.md && git -C
<root-worktree> commit -m "ENG-<id>: plan"`. One commit, after the audit —
not a write-then-amend-then-recommit cycle.

### 8. `ExitPlanMode` for explicit approval

Interactive only. **Do not proceed to Phase B in the same session unless no
`--phase` flag was given to this invocation** — see Headless mode.

### 9. Linear comment + kata mirror

Interactive path (headless equivalent in Headless mode below):

- `mcp__linear-server__save_comment` with a summary and the plan path: one
  comment, bullet lists (Linear corrupts markdown tables with backticked
  cells). Re-read the response to confirm what landed.
- `mcp__linear-server__save_issue` with `assignee: me`, `state: In
  Progress`, set together, per `AGENTS.md` §2. Never set `Done`.
- A **BLOCKING** question only the requester can answer goes in that same
  comment, addressed `@displayName`, not just surfaced in chat.
- **Mirror into kata**, a **local** step-ledger `--phase implement` resumes
  and a human eventually closes with evidence once the PR(s) are actually
  merged (see `/ship-work`'s "After a human merges" reference) — Linear
  stays the source of truth for the ticket, kata just survives a session
  dying mid-build.
  Skip under `--no-issue` unless asked to track anyway.
  - `kata search "ENG-<id>" --agent` first — a `--feedback` re-plan may
    already have one. Reuse it.
  - If none: `kata create "ENG-<id>: <title>" --body "<plan path>"
    --idempotency-key "ENG-<id>" --agent`.
  - Either way: `kata meta set <ref> work.attention ok --agent`, and `kata
    meta set <ref> work.branch haroun/eng-<id>-<slug> --agent`.
  - A **BLOCKING** question also gets `kata meta set <ref> work.attention
    needs-human --agent` + a one-line `work.attention_msg`.
  - kata unavailable, or errors for any reason other than "no match" — note
    it and continue; best-effort local tracking, never a reason to stop.

### 10. Hand back and stop

Report: the decision and why, high level first; the full plan path
including the worktree; every worktree/branch created or reused (Phase B
will **reuse**, never cut a second set); the kata ref alongside the Linear
id/URL; the work-unit list with repos; anything `BLOCKING` as a direct
question; the next command, `/implement-issue --phase implement
<worktree>/docs/plans/<file>.md` (or, with no `--phase`, that Phase B
continues automatically once approved).

**Stop there under `--headless`, or once the human hasn't yet approved.**

## Instructions — Phase B: Implement & Verify

Executes an approved plan. The design is settled; this phase spends nothing
on expensive inference except judgement.

### 1. Pre-flight

Read the plan file **in full** — the source of truth for everything below.
Given `--phase implement`, the plan path is **explicit, never inferred**
(see Headless mode). Interactively with no path, look in the root
worktrees first (`ls -t <root-repo>/wt-eng*-root/docs/plans/*.md`), then the
main checkout; take the newest not in `completed/`, confirm with the human.

Stop before anything else if: an open question is `BLOCKING` and
unresolved; the **Design review** section is missing (this skill's own
Phase A can't produce a plan missing it, but this stays a defense-in-depth
check for a plan predating this convention); the plan's `Status` is
`Completed`.

Then check every touched repo's working tree: `for r in . backend frontend
assistants; do git -C "$r" status -sb; done`. Uncommitted unrelated work is
a stop-and-ask, not something to work around.

**Resume kata tracking.** `kata search "ENG-<id>" --agent` — Phase A already
created this ticket's kata issue at step 9; reuse it. `kata meta set <ref>
work.attention ok --agent` now that a build is starting. If none exists yet
(a plan predating this convention, or `--no-issue`), create one the same way
step 9 does. Kata is a local step-ledger only — the plan file and Linear
remain the sources of truth; point at them rather than duplicating their
content. **Whenever this step, or any stop condition below, would end in a
stop-and-ask interactively or a `NEEDS_HUMAN`/`FAILED` status.json
headlessly, also set `kata meta set <ref> work.attention stuck|needs-human
--agent` plus a one-line `work.attention_msg`, and clear it back to `ok` once
whichever later run resolves it** — never leave the signal stale. If kata is
unavailable or errors for any reason other than "no match," note it and
continue; best-effort tracking, never a reason to stop the build.

**Find out who else is working here.** Concurrent sessions on this repo are
normal:

```bash
git -C <path> worktree list                                   # hard fact
ls -lat ~/.claude/projects/-home-coder-root-for-local/*.jsonl | head  # heuristic
git -C <path> fetch origin <branch> --quiet && git -C <path> rev-parse HEAD origin/<branch>
git -C <path> status --porcelain
```

`worktree list` is definitive (git refuses one branch in two worktrees); the
transcript mtimes are a heuristic; remote drift means someone pushed to your
branch — never force-push over them. All four checks can come back clean
while another session edits a file you're about to; a positive result is a
reason to isolate, and prefer isolating anyway when anything suggests
company.

### 2. Reuse the worktree Phase A made, then rebase it — the ENG-1133 staleness check

**First substantive action after pre-flight, unconditional.** Phase A
already cut a worktree per involved repo, named `wt-eng<id>-{root,be,fe}`.
Find it before creating anything:

```bash
for r in . backend frontend assistants; do
  git -C "$r" worktree list | grep "wt-eng<id>-" && echo "  ^ reuse this"
done
```

Work in whichever exist. Only create one if Phase A didn't (a plan written
before this convention, or a repo its scout missed) — same form as Phase A
step 3, `--no-track` mandatory.

**A reused worktree must be verifiably fresh, or you do not reuse it.**
Before dispatching, for each worktree, establish all three:

```bash
git -C <worktree> status --porcelain              # must be empty
git -C <worktree> log --oneline origin/dev..HEAD  # only the plan commit, if any
git -C <worktree> rev-list --count HEAD..origin/dev  # must be 0 after rebase
```

- **Empty and clean** (nothing uncommitted or stashed, no commits beyond the
  plan) → rebase onto fresh `origin/dev`, continue.
- **Carries uncommitted work** → this is a previous run's unfinished
  implementation, not junk. ENG-1133 left **1465 uncommitted lines** in its
  backend worktree after being killed mid-build; recreating the worktree
  there would have destroyed a real, expensive build. **Stop** and report it
  (`NEEDS_HUMAN` headless) naming the files — a human decides whether to
  commit, stash, or discard.
- **Rebase does not come out clean** → stop, same treatment. Do not force
  anything, do not delete the branch.

Never resolve staleness by deleting a worktree that has content. The only
safe recreate is of a tree with nothing in it. This is exactly the check
Bechir's original `implement-linear-task.md` has none of — it created a
fresh worktree unconditionally every run; that behavior does not survive
here.

**Rebase whatever you reuse, before dispatching anything** — a plan approved
yesterday sits on yesterday's `dev`. `git -C <worktree> fetch origin --quiet
&& git -C <worktree> rebase origin/dev`; `rev-list --count HEAD..origin/dev`
must be `0`.

**Working in a worktree, including for browser QA**: the dev server on 5173
and `python -m app.main` both serve the **main checkout**, so a worktree
change never appears in the browser unless you point a second server at it —
`cd <root-repo>/wt-eng<id>-fe && ln -s ../frontend/node_modules node_modules
&& npx vite --port 5175 --strictPort`. **Port must be 5173-5176**
(`_DEFAULT_CORS_ORIGINS`, `backend/app/main.py:98-101`); an arbitrary high
port 404s and looks like a bug in your change, not a port problem. Never
stage a gitignored sibling's worktree directory that shows up as untracked
in root's status.

**Stacking, only on a declared dependency.** Stack on another branch only
when the plan says this work depends on it, or the unit demonstrably can't
compile/test without code that exists only there. Do not stack merely
because an unpushed branch exists — a wrong guess is expensive in a way that
hides itself (the PR diff carries the parent's commits, CI validates the
wrong base). If stacking is genuine, name the parent branch/PR in the plan
and the PR body, base on the parent, state it must not merge first.

**Base branch per repo**: root/`backend/`/`frontend/` → `dev`;
`assistants/` → `main` (no `dev` branch); `observability/` → `main` is trunk
though `origin/dev` exists. Confirm with `git -C <path> branch -a`, never
assume.

### 3. Dispatch the work units

Group by repo, respect the plan's dependency edges. **Sequential within a
repo** (two agents editing the same checkout fight); **concurrent across
repos** (backend/frontend are separate git repos, send first units in one
message with multiple `Agent` calls).

Default every unit to `subagent_type: "implementer"` (pinned sonnet,
medium effort) — self-contained prompts carrying: the unit's spec verbatim
including its test requirement and "done when," the absolute repo path,
the exact file list (no scope widening), the commands to run (`npm run
build && npm run test:run` for frontend, `poetry run pytest <path>` for
backend), the local-environment facts it would otherwise waste turns
rediscovering (below), that it must **not** commit/push/open a PR, and house
conventions (singular PascalCase Mongo collections, hidden-scrollbar
`DialogContent` classes, no `ENG-###` in comments). Fold unit test *and* e2e
test writing (grounded in Phase A step 4's acceptance scenarios) into the
same prompt rather than as separate steps.

**Escalate by task, not by habit, for the uncommon case only**: a report
flagging genuinely correctness-critical or architectural complexity escalates
to a raw `Agent(model: "opus")` call instead of a stop; rote/mechanical/
boilerplate work may go to a raw `Agent(model: "haiku")` call. This is a
layer on top of the pinned-`implementer` default above, not a replacement of
it — most units stay on `implementer`.

### 4. Escalate rather than letting the cheap model redesign

Trust a passing report — the agent ran the tests and quoted the output; do
not re-read every changed file to double-check what a passing test already
covers.

But when a report says the spec is wrong, a hook doesn't exist, or the
change doesn't fit: **stop that repo's chain and bring it here.** Decide
yourself whether the plan changes, amend the plan file if it does, record
the change in Design review. This is exactly the kind of stop step 1's kata
rule covers — signal `work.attention` before doing anything else, so a
coordinator or the human sees it without reading the transcript. An
implementer improvising around a bad spec is the exact failure this
two-phase split exists to prevent.

### 5. Quality gates, run from this session

```bash
cd frontend && npm run build && npm run test:run                     # TS check + build, unit tests
cd backend  && poetry run pytest <paths touched or exercising them>   # scoped, not the whole repo
cd tests/e2e && npx playwright test                                  # only if e2e specs changed
```

Report **verbatim output**, never predict a result. Running the entire
`poetry run pytest` with no path argument is not required — scope it to the
directories/files each work unit actually touched or that exercise the
changed behavior (mirroring what each unit's own `Done when` already ran),
same as the Light-tier carve-out already did. A full-repo run is slow and
was never the thing that caught real regressions in practice — the
per-unit scoped runs plus the spec-auditor/code-review/blast-radius passes
below are what carry that weight. If a broader sweep is genuinely wanted
(e.g. suspicion that unrelated tests regressed), scope it to the touched
top-level package(s), not the unscoped whole-repo invocation. Skip the full
Playwright suite unless the ticket specifically needs running services.
Known noise, baseline against untouched `dev` before attributing either to
this change: some backend endpoint tests fail in isolation with a pydantic
`AttributeError: id` (Beanie never initialized); ~2 dozen
`test_specs_phase3`/`phase4` failures are `assistants/` template drift,
skipped in CI. `ruff` is not blocking; match neighbours, add no new errors,
don't mass-reformat.

### 6. Spec-auditor, then the fresh-context code review

**Two distinct audits, in this order, both mandatory at every tier** — a
report answering different questions from different inputs, not one
subsuming the other.

**First, `spec-auditor`** (sonnet, read-only): given the plan's behavior
list, the diff (`git -C <path> diff origin/dev...HEAD`), and the test files,
for each behavior it answers whether it's implemented **and would a test
fail if it were removed** — the question nothing else in this chain asks. It
catches a silently-dropped behavior (specified, built, but untested so every
gate still passes) and a tautological test (restates the implementation
rather than the rule). Act on the verdict: `MISSING`/`PARTIAL` in scope →
back to an implementer with the specific gap; `TAUTOLOGICAL` → rewrite the
test to assert the rule, "but it passes" is not a defence; `UNVERIFIABLE` →
the QA artifact's "Needs a human" section, not quietly dropped; behaviors in
the diff the spec never asked for → surface them, unrequested scope is a
human's call and `/ship-work` hard-stops on it later anyway.

**Then, the fresh-context adversarial code review**: `Agent(model: "opus",
effort: "high")` given **only** the raw ticket text, step 4's acceptance
scenarios, and `git -C <path> diff origin/dev...HEAD` — explicitly *not* the
plan, not the plan-audit findings, not any rationale from step 3. It has no
memory of why any line was written, on purpose, so it reviews what the code
actually does. Have it check: does the diff satisfy each acceptance
scenario, any correctness/security issue, anything that only shows up once
code exists (the plan audit couldn't have caught it — no code existed yet).
Fold real findings back into the implementation.

Why both, why in this order: the code reviewer's charter is "does this
satisfy the ticket" and it is never asked, and has no special reason to
notice, whether a specific test would actually fail without the behavior it
claims to cover — that's `spec-auditor`'s one job, and it needs the plan's
behavior list and the test files as explicit inputs, inputs the code
reviewer is deliberately denied to preserve its zero-plan-context guarantee.
Merging them into one pass would either dilute that guarantee or drop the
tautological-test check's rigor.

### 7. Derive the blast radius before doing any QA

Skip the scout dispatch for **Light**; instead state in one line what you
checked for other consumers (a grep for the changed symbol is enough for a
genuinely self-contained change). A Light-tiered change with a real
interaction surface once you look was mis-scoped — say so and go Standard.

The happy path is the easy half; what breaks in production is
**interaction** — something else reads the same data, renders in the same
shell, shares the same cache. Dispatch a `scout` (haiku) with the actual
diff (`git -C <path> diff --stat origin/dev...HEAD`); for every function,
component, hook, endpoint, model field, query key, context value touched, it
returns every other call site/consumer with `path:line`. That list is the QA
surface.

Check the change against the failure classes this codebase actually
produces (each has shipped a real bug here): **tenancy isolation**
(`/o/:orgId/w/:workspaceId/s/:sessionId` scoping — a repeat failure class,
mandatory whenever tenant-scoped data is touched); **permissions/role**
(manager/rep/staff — a silently no-op read-only path looks identical to
success); **real-time** (WebSocket + Redis pub/sub — reconnect after a drop,
a stale token, an event for a different session, two tabs open); **empty,
single, overflowing** (zero/one/past-cap, long strings, first-run state);
**failure and latency** (500s, a disconnected integration, an unsynced
cron); **layout at real widths** (narrow and wide, assert no horizontal
overflow). A changed TanStack Query key or context provider (auth,
WebSocket, streaming, theme) puts every consumer scout found in scope — a
changed cache key serves stale/wrong data to views nobody touched, the
hardest bug class to attribute later.

### 8. QA against that surface, in the browser when `frontend/` changed

Drive the running dev server with Playwright MCP tools, screenshots as
`qa-<ticket>-NN-<what>.png`. Confirm which branch the dev server actually
serves before trusting what you see; browser sessions from a minted token
get logged out — log in with real test credentials or curl the REST
endpoint directly. For **Standard/Heavy**, or any **Light** ticket touching
a UI surface (skip otherwise, say why).

A passing Playwright step is weak evidence alone — it clicks a button behind
another button and reports success. Assert what a click cannot: the element
is genuinely visible, not merely present; the page body doesn't scroll
horizontally; the state *after* the interaction matches the plan, read back
from the UI or API; the neighbouring features scout listed still behave.
Use `tests/e2e/lib/layout-assertions.ts`'s `expectNoHorizontalClipping`/
`expectNotOccluded`/`expectTruncated`/`measureLayout` rather than a hand-
rolled measurement. Anything found here that a test could have caught
becomes a test — a manual QA pass that fixes a bug without leaving a spec
behind guarantees the bug returns.

For backend-only changes there's no browser, but the surface is the same:
exercise the other call sites scout found, tenancy/permission cases
included, against the local API.

**If a scenario needs CRM data that doesn't exist in the sandbox**, seed it
with the Salesforce CLI (`sf`) rather than skipping the scenario or writing
around it — see `docs/runbooks/salesforce-sandbox-local.md`'s "Seeding
QA/test data via the Salesforce CLI" section for the exact commands. Every
seeded record's `Name` starts with `ZZ-TEST ENG-<id>` and is owned by the
already-connected sandbox user; record each created Id in this step's notes
(step 12 deletes them again). Query-then-create — never create a record this
step already confirmed exists. This is safe unsupervised because create and
delete are both scoped to that one prefix; it is still real state in a
sandbox other engineers use, so seed only what the scenario actually needs,
nothing extra "while you're in there."

### 9. Write the QA plan as a durable artifact

Write to `<root-worktree>/docs/plans/qa/<eng-id>-qa.md` (create the `qa/`
directory if needed). Start with a machine-readable header, this exact
order and keys:

```
Issue: ENG-<id>
Commit: <the SHA step 5's gates were run against, one per touched repo, e.g. "backend abc1234, frontend def5678">
Gates: <verbatim pass/fail summary per gate command, e.g. "frontend build+test:run PASS, backend pytest PASS">
UI: <the URL to open in a browser to see this change, with its port — e.g. "changed http://localhost:5175 (api :8001) | baseline http://localhost:5173 (api :8000)". "none — <reason>" if there is genuinely no UI surface.>
Relaunch: <exact commands to bring the changed pair up on demand — worktree paths, ports, the .env.local copy, the node_modules symlink, and the 5173-5176 CORS window caveat>
E2E: <exact command to run this issue's e2e spec against the changed pair's ports, e.g. "cd tests/e2e && E2E_BASE_URL=http://localhost:5175 E2E_API_URL=http://localhost:8001/api/v1 npx playwright test tests/cockpit/cockpit-eng1234-foo.spec.ts --project=chromium". "none — <reason>" if no e2e spec covers this change.>
PRs: (filled in once opened, by step 13)
```

**`UI:` is mandatory on every artifact, at every tier, with no exceptions.**
It exists so the human can open the change in a browser without reading the
rest of the file or reconstructing a command — a bare URL they can click,
plus the port, plus which API port that frontend is pointed at (the frontend's
own `.env` decides this, and it is routinely NOT 8000 — check it rather than
assuming). State the **baseline** URL alongside the changed one whenever both
are meaningful, since the entire point is comparing them.

Write `UI:` even when this run left no server running — it names where the
change *will* be once `Relaunch:` is run, and the two are read together. For a
change with no UI surface at all (backend-only, a migration, tooling), write
`none — <one-line reason>` rather than omitting the key: an absent key reads as
an oversight, and a reader cannot tell "no UI" from "forgot to say."
Never write a port here that this run did not actually verify serves the
changed code — confirm with `ss -ltnp` and by loading the page, because a URL
that silently serves the *baseline* checkout produces a QA pass that proves
nothing (the worktree/`5173` trap in step 2).

**`E2E:` is mandatory too, same rule as `UI:`.** Check whether the root PR's
diff touches `tests/e2e/tests/**` (a new or updated spec for this issue) —
if it does, write the exact runnable command, `E2E_BASE_URL`/`E2E_API_URL`
pointed at the changed pair's actual ports (from `Relaunch:`), not the
baseline's. This is what turns the human's own pass into a copy-paste
instead of a rediscovery of `tests/e2e/.env.e2e.example`'s two variables.
If this change has no e2e spec — most Light tickets, and any change that
isn't `frontend/`-facing — write `none — <reason>` (e.g. "none — no e2e
spec covers this surface" or "none — backend-only change").

Below the header, the same four sections, **by exact heading** (`ship-work`
and `test-issue` both parse these verbatim):

1. **Verified here** — the evidence: what was run or clicked, and the
   result.
2. **Needs a human** — and why the agent couldn't reach it; be specific, not
   vague (a vague gap gets skipped).
3. **Interaction cases from the blast radius** — named individually, not
   summarized. For a Light plan with a genuinely empty blast radius, one
   line ("none: self-contained, checked via `grep -rn <symbol>`") is honest
   content, not a gap to pad out.
4. **Edge cases from the plan**, plus any the QA pass added. For Light
   without an Edge cases section, one line on what would make this fail is
   enough.

Assume the app is live and a regression is visible to customers. State
plainly what was **not** covered.

Commit the artifact in its own commit, subject `ENG-<id>: add QA plan
artifact` — not folded into a work-unit commit, since `/ship-work`'s later
one-line edit to the `PRs:` line then touches a file nothing else is
mid-editing. Report it in chat (step 10), and in headless mode post its
header + a one-line pointer to the inbox issue marked `Phase: implement`
(informational, not a question) — the **file is the source of truth**, the
inbox post is a courtesy copy. Headless runs also record the artifact's
absolute path in `status.json`'s `detail`.

### 10. Stop and report

High level first: what was built per work unit with a one-line reason;
verbatim test/build output; screenshots if any; the QA plan; anything not
implemented and precisely why (scaling down is the human's call).

Do **not** ask approval to commit or run roborev — both stay on this
machine and are trivially reversible. Do **not** ask approval to push or open
the PR(s) either (step 13, coming next) — invoking this skill already
authorizes what it declares, per `AGENTS.md`'s Permission section. What still
needs explicit approval: merging (never done by anything in this chain — a
human's own separate action) and Linear writes.

### 11. Commit, then review

Subject `ENG-<id>: <what changed>`, one coherent unit per commit:

- stage with **explicit paths**, never `git add -A` (has leaked live
  secrets from this tree before);
- `git -C <abs-path>` per repo;
- trailers: only the human's two `Co-Authored-By` lines. The tracked
  `commit-msg` hook adds both idempotently and strips assistant trailers for
  local commits; it does **not** fire for GitHub-API/web-UI commits — write
  them by hand there, verify with `git -C <path> log -1 --format=%B`;
- small fixups on an unmerged branch of the human's own → `--amend`, not a
  follow-up commit.

```bash
roborev review --branch --base origin/dev --wait --repo <abs-repo-path>
```

`--base origin/main` for `assistants/`. No `--agent`/`--model` flag needed —
roborev's global config pins reviews to `claude-code`+`sonnet`. Exit 1 means
a Fail verdict (findings), not a crash — read the output before reporting an
error. Offer `/roborev-fix`. Cross-repo findings about gitignored siblings
are usually noise; verify the frontend yourself rather than looping on them.

### 12. Stop what you started; record how to relaunch it

Whatever step 8's own QA started (the worktree frontend on 5173-5176, a
worktree or main-checkout backend) gets stopped in this step — verify with
`ss -ltnp` before and after. **Never touch the baseline pair (5173/8000)** —
nothing here started it. Instead of a live server, hand over the **exact
relaunch recipe** (worktree paths, ports, the `.env.local` copy, the
`node_modules` symlink, the CORS-window caveat) into the QA artifact's
`Relaunch:` header — its only home; don't also try to keep it fresh in
chat. `/test-issue` starts the changed pair later, on demand, from that same
header.

**Also delete anything step 8 seeded in the Salesforce sandbox** — the
`ZZ-TEST ENG-<id>` query-then-delete from the runbook's seeding section,
same prefix, one pass per object type seeded (children before parents). A
sandbox record left behind is not this run's process to clean up later; if
the query matches zero rows, that's fine and expected — nothing was seeded,
or a fixture the human seeded by hand outside the prefix was correctly left
alone.

### 13. Push and open the PR(s) — no server, no Docker

Pure git and GitHub-API from here: rebase, push, open a PR. Nothing needs to
be running locally to do this — no dev server, no database, no
`dockerize-local`. Whatever step 5's gates and step 8's QA already proved
stands; this step re-runs none of it, it only ships what already passed.

**Gate on scope, then on secrets first** — the same two checks `/ship-work`
used to run right before its own push, moved here since this is now the step
that pushes. Either one failing is a stop-and-report (interactive) /
`NEEDS_HUMAN` (headless) — never push past it:

- **Scope.** Per repo, `git -C <path> diff --name-only origin/dev...HEAD` and
  `git -C <path> status --porcelain`, compared against the union of the
  plan's per-unit file lists. A file outside the plan — an implementer that
  widened scope, or a stray unrelated edit — stops here and gets reported
  individually. Test files the plan implied but didn't name by exact path are
  fine; new source files it never mentioned are not.
- **Secrets.** Before anything leaves the machine:
  ```bash
  git -C <path> diff --cached -U0 | grep -nE \
    'sk-[A-Za-z0-9]{16,}|sk_live_|rk_live_|AKIA[0-9A-Z]{16}|xox[baprs]-|ghp_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  ```
  Any hit stops the run — except a hit whose only match is this regex's own
  source text in a `.claude/` doc; never loosen the pattern to make that go
  away.

**Rebase onto fresh `dev` once, per repo, before pushing** — a plan approved
earlier sits on an earlier `dev`:

```bash
git -C <path> fetch origin dev --quiet   # main for assistants/observability
git -C <path> rebase origin/dev
```

Resolve deterministically or stop, the same three classes `/ship-work`
allows and nothing else: lockfiles (`package-lock.json`, `poetry.lock` — take
theirs, regenerate with the real tool), import-ordering/formatter-only
churn, append-only list files where both sides added a distinct line.
Anything else is a semantic conflict — stop, name the files, do not guess
which intent wins. This is the only rebase this phase does; re-rebasing
after a sibling PR merges is `/ship-work`'s job (its own step 6), tied to the
merge-ordering it alone performs.

**Push, and verify by content, not by the command's output:**

```bash
git -C <path> push -u origin <branch>
git -C <path> fetch origin <branch> --quiet
git -C <path> diff --stat HEAD origin/<branch>    # must be empty
```

**Open one PR per repo**, `mcp__github__create_pull_request`, base per repo
(`dev`; `main` for `assistants/`/`observability/`):

- title `ENG-<id>: <what changed>`
- body, in this order: what changed and why (two or three lines), the work
  units it covers, verbatim test evidence, the QA plan, a link/path to the
  plan doc, screenshots from browser QA
- **`Part of ENG-<id>`** in the body — never `Fixes`/`Closes`/`Resolves`
  (those auto-close the Linear-linked issue; only a reviewer marks it `Done`)
- cross-link sibling PRs by URL when the ticket spans repos, and state the
  required landing order in each body — the human merging reads this to
  decide the order, since neither this skill nor `/ship-work` merges

**Fill the QA artifact's `PRs:` line** once every PR is open — edit
`docs/plans/qa/<eng-id>-qa.md`'s header, replace the placeholder with the
opened URLs (`PRs: backend <url>, frontend <url>, root <url>`), commit that
one-line edit on its own: `ENG-<id>: record PR URLs in QA artifact`.

**Never wait for CI, never merge here** — neither this step nor `/ship-work`'s
own next pass ever does either; both stop at a pushed, rebased, locally
gate-clean PR and leave CI-watching and merging to the human.

### 14. Hand off to `/ship-work` to confirm the push is solid

This phase ends at a pushed branch with an open, roborev-reviewed PR (or
PRs), and **stops there**.

**Never merge, never archive the plan, never move the Linear status** — not
even when every check is obviously green. None of that happens in this
chain at all: merging, and everything that follows a merge (Linear
`Staging`, the plan archive, kata close, worktree cleanup), is a human's own
separate action once they've reviewed and merged the PR(s) themselves,
documented as reference in `/ship-work`'s "After a human merges" section.
**This explicitly replaces Bechir's original `implement-linear-task.md` steps
that locally merged into `dev` and then dockerized/e2e'd against that merge —
those are dropped entirely, not adapted.** `/ship-work` keeps the ability to
push/open a PR itself as a fallback for a plan predating this convention or a
manual invocation, but the normal path is that step 13 already did it — and
in neither path does it merge.

**Leave the kata issue open, `work.attention ok`** — do not close it.
Closing with evidence happens once a human has actually merged the code and
asks for the closeout, per `/ship-work`'s reference section for that.

End every run by handing the human their own pre-ship QA pass, not just a
merge command — the goal is that running through it themselves is what
earns the confidence to push into staging, not the agent's say-so alone:

> Implementation is committed on `<branch>` in `<repos>`, roborev is clean,
> and the PR(s) are open: `<urls>`.
>
> **To verify it yourself before shipping:**
> 1. Frontend (linked to its own backend): `<changed URL with port>` (baseline
>    `<baseline URL with port>` for comparison) — servers are
>    `<running | stopped; relaunch with the artifact's Relaunch: header>`.
> 2. QA doc, walk it scenario by scenario: `docs/plans/qa/<eng-id>-qa.md`
>    (commit `<sha>`, gates `<pass/fail>`) — check off **Verified here**,
>    **Needs a human**, **Interaction cases**, and **Edge cases** as you go.
> 3. E2E, if this issue has a spec: `<E2E: command from the artifact>`
>    (`none — <reason>` otherwise).
>
> Once you've run the scenarios and they hold up, run
> `/ship-work docs/plans/<plan>.md` to confirm it's rebased onto the latest
> `dev` and locally gate-clean, then merge it yourself once CI is green.

**Always include all three lines verbatim from the artifact's `UI:`,
`Relaunch:`, and `E2E:` headers** (`none — <reason>` for either of the
latter two when there's genuinely nothing to run). The human reads this
message far more often than the artifact, and "where do I click, what do I
click through, and how do I run the e2e spec" are the three follow-up
questions that otherwise get asked every time — answering all three
unprompted, with ports already filled in, is worth the extra lines.

Say it even when the run stopped early, adjusted for what's left.

### Local environment facts for this workspace (autopilot and interactive)

These cost real runs real money to rediscover; do not re-derive them.

- **Databases are on plain `localhost`** — `localhost:27017` (mongo),
  `localhost:6379` (redis), no gateway address needed. `backend/.env.local`
  points at these.
- **Native libs need `LD_LIBRARY_PATH`** — `import numpy` fails with
  `libz.so.1` missing (zlib, not libstdc++), cascading through
  `qdrant_client` → `grpc`, making `app.main` unimportable.
  `autopilot/bin/ap-env.sh` exports the discovered paths, so autopilot acts
  already have it.
- **Export the env file, don't just rely on it** — `OPENAI_API_KEY` is read
  from the raw environment, so `set -a; . ./.env.local; set +a`; the file
  must be LF, not CRLF.
- **Verified recipe** (from `backend/`): export the env file, ensure
  `LD_LIBRARY_PATH`, then `poetry run pytest <paths> -q --no-cov` — a
  single-file run otherwise trips the repo-wide 40% coverage gate, which is
  the threshold talking, not your change.
- **Playwright is available** — chromium installed, `mcp__playwright__*`
  allowed in the autopilot profile. Browser QA is expected, not optional.

## Headless mode (`--headless`)

Read `.claude/skills/autopilot-protocol.md` first — the `status.json` shape,
the inbox contract, the ask→fallback rule, the Linear footprint are defined
once there. This section states only what this skill's own ask points map
to.

**The interactive/headless fork, stated plainly:** with no `--phase` flag,
this skill behaves exactly as described above — `ExitPlanMode`'s approval
leads straight into Phase B in the same session. **`--headless` requires an
explicit `--phase plan|implement` and never free-flows between them** — a
`claude -p` process cannot synchronously block for hours waiting on the
owner's `go` comment the way `ExitPlanMode` assumes interactively.
`ap-cycle.sh` dispatches these as two genuinely separate invocations,
potentially hours apart, decided by two separate poll cycles.

### `--phase plan`

**Input is always an existing issue id**, extracted by `autopilot-poll` from
the inbox issue's title — never free text: `--phase plan <description>
--headless` with no issue id is `FAILED`, `detail: "headless requires an
issue id"`. Step 1's create-a-ticket path is interactive-only.

This phase's `NEEDS_HUMAN` inbox comments start with `Phase: plan`.

**Ask-point mapping** (step 1, only reachable given an issue id):

- **Duplicate-ticket match**: plan the existing matching issue instead of
  the one passed in, record the choice as an inbox comment. Do not ask.
- **Description too thin**: `NEEDS_HUMAN` — post the specific question that
  resolves it.
- **Project-selection coin flip**: take the first matching rule in step 1's
  priority order, record the assumption as an inbox comment. Do not ask.
- **"agent type not found" dispatch failure**: `FAILED` with that detail — no
  unattended remedy for a session predating the agent definitions.

**`--feedback '<text>'`**: treat as new requirements, not a mechanical
correction. Revise the committed plan in place — same file, same branch, a
new commit — and **re-run step 7's audit against the revision** before
recommitting (a small strengthening beyond simply reposting: a revision
changes claims that need re-verification). Post the revised plan to the
inbox as a comment, same as a fresh plan.

**Linear claim + kata mirror, first thing:** at the start of a headless run,
before any exploration or drafting — claim the issue (`assignee: me`,
`state: In Progress`) and do step 9's kata search/create + `work.branch`/
`work.attention ok` calls, unconditionally, `--feedback` re-plans included
(re-claiming an already-claimed issue, or re-finding an already-created kata
issue, is a harmless no-op). This is the only place the Linear claim can
happen headlessly — `ap-decide.sh` has no Linear credential of its own.
`kata` needs no permission-profile ask beyond the allow-listed `Bash(kata
*)`; if it errors for any reason other than "no match," record a one-line
note in `status.json`'s `detail` and continue.

**End state:** commit the plan exactly as step 7 does interactively. Create
or update the inbox issue with the **full** plan markdown, prefixed `Plan
file: <absolute path>`, label `plan-review`, write `status.json` with
`status: DONE`, `phase: "plan"`, `plan_path` set. **Stop there — do not
begin Phase B.** Step 9's Linear plan-summary comment is interactive-only
and skipped headlessly; the claim already happened above.

**Blocking open question surviving the audit** (step 5's `BLOCKING` marker):
still post the plan to the inbox, but label `needs-input` instead of
`plan-review`, write `status.json` with `status: NEEDS_HUMAN` and `question`
set to the blocking text. Also `kata meta set <ref> work.attention
needs-human --agent` and `work.attention_msg` to the same question — clear
back to `ok` on whichever later run resolves it.

### `--phase implement <plan_path>`

**Plan path is always explicit** — step 1's "newest unarchived plan"
inference and "confirm with the human" are interactive-only. A headless
invocation with no explicit plan path writes `status.json` with `status:
FAILED`, `detail: "headless requires an explicit plan path"`, and ends
without touching the inbox.

**Before writing `NEEDS_HUMAN` at any of these stop points, stop any dev
servers this run has already started** (the worktree frontend/backend from
step 9's QA, if reached) — same discipline step 12 already requires before
`DONE`, now required before parking too (see `autopilot-protocol.md`'s
"Parking" section): a lane slot freed at park time can otherwise be handed
to a fresh act whose assigned ports collide with servers this run left
bound.

**Step 1/2's stop conditions**, mapped per the ask→fallback rule:

- **BLOCKING unresolved** — `NEEDS_HUMAN`, `question` the exact text.
- **Design review missing** — not an ask with a fallback: `FAILED`,
  `detail: "plan was never dry-run reviewed; a human must re-plan"`. Do not
  attempt the audit yourself.
- **Uncommitted unrelated work** — `NEEDS_HUMAN`, the exact `git status -sb`
  output quoted in `question`.
- **Worktree carries uncommitted work, or a rebase conflict** (step 2's
  ENG-1133 check) — `NEEDS_HUMAN`, naming the files, exactly as interactive.

**Step 4's escalation** — spec-wrong/hook-missing/doesn't-fit reports:
`NEEDS_HUMAN`, the finding posted verbatim as `question`. The plan is never
amended headlessly.

**Step 13's stop conditions** — no documented default for either, so both
resolve via the ask→fallback rule's `NEEDS_HUMAN` branch, never a silent
skip:

- **Out-of-plan file** (the scope gate) — `NEEDS_HUMAN`, the file list quoted
  in `question`.
- **Secret-shaped string hit, or a semantic rebase conflict** — `NEEDS_HUMAN`,
  the finding (or the conflicting file list) quoted in `question`. Never push
  past either.

**Server policy** (step 12): run the full QA including the baseline
comparison, exactly as interactive — headless QA is not lighter QA. Stop the
changed-pair servers this run started; the baseline pair is never something
this run started either way. Write the relaunch recipe into the QA
artifact's `Relaunch:` header (the durable copy), then record the
**artifact's absolute path** in `status.json`'s `detail` and post it as an
inbox comment prefixed `Phase: implement`. Verify teardown with `ss -ltnp`
before/after.

**`--ports fe=<n>,be=<m>`** overrides steps 2/12's 5173-5176 range — bind
exactly those two ports (never the baseline pair 5173/8000), and start the
worktree backend with `BACKEND_CORS_ORIGINS` set to a JSON list containing
`http://localhost:<feport>` (this **replaces**, not extends, the default
allowlist — omitting it reproduces the same broken-page failure for a
different port range).

**End state:** commit exactly as interactive (step 11), run `roborev`
exactly as interactive, then run step 13 exactly as interactive — gate on
scope/secrets, rebase, push, open the PR(s), fill and commit the QA
artifact's `PRs:` line. Write `status.json` with `status: DONE`, `phase:
"implement"`, `plan_path` set, `pr_urls` filled with every opened PR URL,
`detail` = the QA artifact's absolute path. Post the PR URL(s) as part of
the same `Phase: implement` inbox comment step 9 already writes. Do **not**
change the inbox label — it stays `building`; the wrapper swaps it to
`shipping` right after seeing this `DONE`, before invoking the ship phase.
Roborev findings never block a `DONE` write — record in `detail`.

**Pushing and opening PRs is pre-approved headlessly** — step 13 runs
exactly as interactive, no different gate. Merging is never autonomous:
"never merge, never move Linear status beyond the claim" applies identically
headlessly, and stays entirely `/ship-work`'s job.

**Never end the turn with work still in the background.** The headless `-p`
harness kills the session outright once its background-wait ceiling passes —
no final message, no `status.json`, and the wrapper reconciles a healthy run
as a crash. Run the quality gates and CI-adjacent waits as **blocking
foreground commands**, never parked as background tasks you "wait on," and
treat writing `status.json` as the last thing that must complete before
anything else is allowed to still be running. If a long suite genuinely
can't finish inside the turn, write an interim `status.json` (`FAILED`,
detail "gates still running at turn end") first and let the retry recover —
never leave the file unwritten while waiting.
